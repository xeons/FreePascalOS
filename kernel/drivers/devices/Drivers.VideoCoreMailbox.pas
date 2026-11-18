{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The Raspberry Pi's VideoCore mailbox: the property channel to the GPU
  firmware (board model, revision, serial number and Ethernet address,
  clock rates, temperature, power domains).

  The mailbox is the ACPI device BCM2849 (RPIQ, at FE00B880h on the Pi
  4). Mailbox 0 carries the firmware's answers to the processors, mailbox
  1 the processors' requests:

    00h  mailbox 0 read      18h  mailbox 0 status (bit 30: empty)
    20h  mailbox 1 write     38h  mailbox 1 status (bit 31: full)

  A request is the bus address of a message (16-byte aligned) with the
  channel in its low four bits (8: properties from the processors). The
  message: its length in bytes, a code (0 for a request; 80000000h when
  the firmware answered), then tags (an id, the size of its value
  buffer, a code that the answer sets to 80000000h + the answer's length,
  the value) and a zero end tag.

  The message lives in one page below 1 GiB, mapped uncached: the
  firmware reads and writes RAM without looking at the processors'
  caches. Its bus address is what the device's _DMA says (the GPU sees
  RAM at C0000000h on the Pi 4); without _DMA that alias is used.
  Requests are polled, one at a time.
}
unit Drivers.VideoCoreMailbox;

{$mode objfpc}
{$pointermath on}

interface

const
  { Tags. }
  FirmwareTagFirmwareRevision = $00000001;
  FirmwareTagBoardModel = $00010001;
  FirmwareTagBoardRevision = $00010002;
  FirmwareTagBoardMacAddress = $00010003;
  FirmwareTagBoardSerial = $00010004;
  FirmwareTagArmMemory = $00010005;
  FirmwareTagSetPowerState = $00028001;
  FirmwareTagClockRate = $00030002;
  FirmwareTagMaximumClockRate = $00030004;
  FirmwareTagTemperature = $00030006;
  FirmwareTagMaximumTemperature = $0003000A;
  FirmwareTagNotifyXhciReset = $00030058;

  { Clock ids. }
  FirmwareClockEmmc = 1;
  FirmwareClockUart = 2;
  FirmwareClockArm = 3;
  FirmwareClockCore = 4;
  FirmwareClockEmmc2 = 12;

  { Power domain ids. }
  FirmwarePowerSdCard = 0;
  FirmwarePowerUsb = 3;

  { The most 32-bit words a tag's value may take here. }
  MaximumTagWords = 64;

{ Finds the mailbox among the ACPI platform devices; True if there is
  one (only on a Raspberry Pi). }
function InitializeVideoCoreMailbox: Boolean;
function VideoCoreMailboxIsAvailable: Boolean;
{ The physical address of the mailbox's registers (0 without one): the
  other peripherals are found from it (the Pi's PM watchdog). }
function VideoCoreMailboxPhysicalAddress: QWord;

{ Sends one tag: Words holds RequestWords words of request and room for
  ValueWords words of answer (at most MaximumTagWords). True if the
  firmware answered it; AnswerBytes is how long the answer is. }
function QueryFirmwareTag(Tag: LongWord; Words: PLongWord; RequestWords, ValueWords: LongWord;
  out AnswerBytes: LongWord): Boolean;

{ Convenience queries; each False if there is no mailbox or no answer. }
function QueryFirmwareWord(Tag: LongWord; out Value: LongWord): Boolean;
function QueryClockRate(ClockId: LongWord; out Hertz: LongWord): Boolean;
function QueryMaximumClockRate(ClockId: LongWord; out Hertz: LongWord): Boolean;
{ Thousandths of a degree Celsius. }
function QueryTemperature(out MilliCelsius: LongWord): Boolean;
function QueryBoardSerial(out Serial: QWord): Boolean;
function QueryBoardMacAddress(Address: PByte): Boolean;
function QueryArmMemory(out Base, Size: LongWord): Boolean;
{ Switches power domain DeviceId on or off and waits for it. }
function SetFirmwarePowerState(DeviceId: LongWord; TurnOn: Boolean): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Kernel.Mutex,
  Kernel.Clock,
  Kernel.Arch.Cpu,
  Io.Dma,
  Io.PlatformDevices,
  Debug.Output;

const
  MailboxRead = $00;
  MailboxReadStatus = $18;
  MailboxWrite = $20;
  MailboxWriteStatus = $38;
  MailboxRegisterSpan = $40;
  StatusFull = LongWord($80000000);
  StatusEmpty = LongWord($40000000);

  PropertyChannel = 8;
  CodeRequest = 0;
  CodeSuccess = LongWord($80000000);
  TagAnswered = LongWord($80000000);

  TimeoutMilliseconds = 1000;

  { How the GPU sees the low gigabyte of RAM on the BCM2711 (the alias
    that bypasses its L2 cache). }
  DefaultBusOffset = QWord($C0000000);
  DefaultWindowLength = QWord($40000000);

var
  Registers: PByte;
  RegistersPhysical: QWord;
  Message: TDmaBuffer;
  { The mailbox's DMA: never coherent, through the GPU's window. }
  MailboxDma: TDmaAttributes;
  Lock: TMutex;
  Available: Boolean;

function ReadRegister(Offset: LongWord): LongWord;
begin
  Result := PLongWord(Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteRegister(Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Registers + Offset)^ := Value;
end;

function WaitWhileSet(Offset: LongWord; Bit: LongWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(TimeoutMilliseconds);
  while (ReadRegister(Offset) and Bit) <> 0 do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

{ Sends the message and waits for the firmware's answer to it. }
function Exchange: Boolean;
var
  Request: LongWord;
  Answer: LongWord;
begin
  Result := False;
  { Old answers nobody waited for are dropped. }
  while (ReadRegister(MailboxReadStatus) and StatusEmpty) = 0 do
    ReadRegister(MailboxRead);
  Request := LongWord(Message.DeviceAddress and not QWord($F)) or PropertyChannel;
  if not WaitWhileSet(MailboxWriteStatus, StatusFull) then
    Exit;
  WriteRegister(MailboxWrite, Request);
  repeat
    if not WaitWhileSet(MailboxReadStatus, StatusEmpty) then
      Exit;
    Answer := ReadRegister(MailboxRead);
  until Answer = Request;
  Result := PLongWord(Message.Address)[1] = CodeSuccess;
end;

function QueryFirmwareTag(Tag: LongWord; Words: PLongWord; RequestWords, ValueWords: LongWord;
  out AnswerBytes: LongWord): Boolean;
var
  Body: PLongWord;
  Index: LongWord;
  TagCode: LongWord;
begin
  Result := False;
  AnswerBytes := 0;
  if not Available or (ValueWords > MaximumTagWords) or (RequestWords > ValueWords) then
    Exit;
  AcquireMutex(Lock);
  Body := PLongWord(Message.Address);
  Body[0] := (5 + ValueWords + 1) * 4;
  Body[1] := CodeRequest;
  Body[2] := Tag;
  Body[3] := ValueWords * 4;
  Body[4] := RequestWords * 4;
  for Index := 1 to ValueWords do
    if Index <= RequestWords then
      Body[4 + Index] := Words[Index - 1]
    else
      Body[4 + Index] := 0;
  Body[5 + ValueWords] := 0;
  { The page is uncached, so this only orders the writes before the
    doorbell (and keeps a cached mapping correct too). }
  PrepareDmaToDevice(MailboxDma, Message.Address, Body[0]);
  if Exchange then
  begin
    FinishDmaFromDevice(MailboxDma, Message.Address, Body[0]);
    TagCode := Body[4];
    if (TagCode and TagAnswered) <> 0 then
    begin
      AnswerBytes := TagCode and not TagAnswered;
      for Index := 1 to ValueWords do
        Words[Index - 1] := Body[4 + Index];
      Result := True;
    end;
  end;
  ReleaseMutex(Lock);
end;

function QueryFirmwareWord(Tag: LongWord; out Value: LongWord): Boolean;
var
  Words: array[0..1] of LongWord;
  AnswerBytes: LongWord;
begin
  Words[0] := 0;
  Words[1] := 0;
  Result := QueryFirmwareTag(Tag, @Words[0], 0, 2, AnswerBytes) and (AnswerBytes >= 4);
  Value := Words[0];
end;

{ A tag whose request is an id and whose answer is the id and a value. }
function QueryIdAndValue(Tag: LongWord; Id: LongWord; out Value: LongWord): Boolean;
var
  Words: array[0..1] of LongWord;
  AnswerBytes: LongWord;
begin
  Words[0] := Id;
  Words[1] := 0;
  Result := QueryFirmwareTag(Tag, @Words[0], 1, 2, AnswerBytes) and (AnswerBytes >= 8) and (Words[0] = Id);
  Value := Words[1];
end;

function QueryClockRate(ClockId: LongWord; out Hertz: LongWord): Boolean;
begin
  Result := QueryIdAndValue(FirmwareTagClockRate, ClockId, Hertz) and (Hertz <> 0);
end;

function QueryMaximumClockRate(ClockId: LongWord; out Hertz: LongWord): Boolean;
begin
  Result := QueryIdAndValue(FirmwareTagMaximumClockRate, ClockId, Hertz) and (Hertz <> 0);
end;

function QueryTemperature(out MilliCelsius: LongWord): Boolean;
begin
  Result := QueryIdAndValue(FirmwareTagTemperature, 0, MilliCelsius);
end;

function QueryBoardSerial(out Serial: QWord): Boolean;
var
  Words: array[0..1] of LongWord;
  AnswerBytes: LongWord;
begin
  Words[0] := 0;
  Words[1] := 0;
  Result := QueryFirmwareTag(FirmwareTagBoardSerial, @Words[0], 0, 2, AnswerBytes) and (AnswerBytes >= 8);
  Serial := Words[0] or (QWord(Words[1]) shl 32);
end;

function QueryBoardMacAddress(Address: PByte): Boolean;
var
  Words: array[0..1] of LongWord;
  AnswerBytes: LongWord;
begin
  Words[0] := 0;
  Words[1] := 0;
  Result := QueryFirmwareTag(FirmwareTagBoardMacAddress, @Words[0], 0, 2, AnswerBytes) and (AnswerBytes >= 6);
  if Result then
    CopyMemory(Address, @Words[0], 6);
end;

function QueryArmMemory(out Base, Size: LongWord): Boolean;
var
  Words: array[0..1] of LongWord;
  AnswerBytes: LongWord;
begin
  Words[0] := 0;
  Words[1] := 0;
  Result := QueryFirmwareTag(FirmwareTagArmMemory, @Words[0], 0, 2, AnswerBytes) and (AnswerBytes >= 8);
  Base := Words[0];
  Size := Words[1];
end;

function SetFirmwarePowerState(DeviceId: LongWord; TurnOn: Boolean): Boolean;
const
  StateOn = 1;
  StateWait = 2;
  StateMissing = 2;
var
  Words: array[0..1] of LongWord;
  AnswerBytes: LongWord;
begin
  Words[0] := DeviceId;
  Words[1] := StateWait;
  if TurnOn then
    Words[1] := Words[1] or StateOn;
  Result := QueryFirmwareTag(FirmwareTagSetPowerState, @Words[0], 2, 2, AnswerBytes) and
    ((Words[1] and StateMissing) = 0) and (((Words[1] and StateOn) <> 0) = TurnOn);
end;

{ --- Finding it --------------------------------------------------------------- }

function ProbeMailbox(Device: PPlatformDevice): Boolean;
var
  Start: QWord;
  Length: QWord;
begin
  Result := False;
  if Available or not PlatformMemoryRange(Device, 0, Start, Length) then
    Exit;
  Registers := PByte(MapPlatformMemory(Device, 0, Length));
  if Registers = nil then
    Exit;
  RegistersPhysical := Start;
  { (The _CRS may name only the first 24h bytes; the page is mapped.) }
  MailboxDma := Device^.Dma;
  { The GPU never looks at the processors' caches. }
  MailboxDma.Coherent := False;
  if MailboxDma.WindowCount = 0 then
  begin
    MailboxDma.WindowCount := 1;
    MailboxDma.Windows[0].PhysicalStart := 0;
    MailboxDma.Windows[0].BusStart := DefaultBusOffset;
    MailboxDma.Windows[0].Length := DefaultWindowLength;
  end;
  if not AllocateDmaBuffer(MailboxDma, (5 + MaximumTagWords + 1) * 4, DmaShared, Message) then
    Exit;
  InitializeMutex(Lock);
  Available := True;
  Result := True;
end;

const
  MailboxIds: array[0..1] of PChar = ('BCM2849', nil);
  MailboxDriver: TPlatformDriver = (
    Name: 'videocore-mailbox';
    Ids: @MailboxIds[0];
    Probe: @ProbeMailbox);

function InitializeVideoCoreMailbox: Boolean;
var
  Revision: LongWord;
begin
  Result := BindPlatformDriver(MailboxDriver) > 0;
  if not Result then
    Exit;
  DebugBeginMessage;
  DebugWriteTag('mailbox');
  DebugWrite('VideoCore mailbox, message at bus address ');
  DebugWriteHex(Message.DeviceAddress, 8);
  if QueryFirmwareWord(FirmwareTagFirmwareRevision, Revision) then
  begin
    DebugWrite(', firmware revision ');
    DebugWriteHex(Revision, 8);
  end
  else
    DebugWrite(', the firmware does not answer');
  DebugWriteLine('');
  DebugEndMessage;
end;

function VideoCoreMailboxIsAvailable: Boolean;
begin
  Result := Available;
end;

function VideoCoreMailboxPhysicalAddress: QWord;
begin
  if Available then
    Result := RegistersPhysical
  else
    Result := 0;
end;

end.
