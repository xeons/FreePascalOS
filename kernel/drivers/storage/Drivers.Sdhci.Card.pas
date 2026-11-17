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
  SD memory cards on an SD host (Drivers.Sdhci.Host): bringing a card
  up and moving its blocks.

  Bringing it up, as the SD Physical Layer specification has it:
    CMD0   to the idle state
    CMD8   interface condition (2.7-3.6 V, check pattern 1AAh): answered
           by cards of version 2.00 and later, which may be high capacity
    ACMD41 (CMD55 + CMD41) until the card is ready, offering high
           capacity to version 2 cards; the answer's CCS bit says whether
           it is SDHC/SDXC (addressed by block) or SDSC (by byte)
    CMD2   its identification (CID: maker, product name, serial)
    CMD3   its relative address (RCA)
    CMD9   its specific data (CSD: the capacity)
    CMD7   select it (to the transfer state)
    CMD16  512-byte blocks (for SDSC cards)
    ACMD51 its configuration (SCR: the bus widths and specification
           version it has)
    ACMD6  a 4-bit bus, if it has one
    CMD6   high speed (function group 1, function 1), if the card has
           CMD6 (specification 1.10 and later) and the host can clock
           at 50 MHz; else 25 MHz
  The host stays at 3.3 V signalling: UHS-I modes (1.8 V) are not used.

  Blocks: CMD17/CMD18 read and CMD24/CMD25 write one or several 512-byte
  blocks (several end with an automatic CMD12), at most the host's
  bounce buffer at a time; a failed piece is tried once more.
}
unit Drivers.Sdhci.Card;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drivers.Sdhci.Host;

type
  TSdCard = record
    Rca: LongWord;
    { Addressed by block (SDHC, SDXC) rather than by byte (SDSC). }
    HighCapacity: Boolean;
    { Answered CMD8: specification 2.00 or later. }
    Version2: Boolean;
    BlockCount: QWord;
    Cid: array[0..3] of LongWord;
    Csd: array[0..3] of LongWord;
    Scr: array[0..7] of Byte;
    ProductName: array[0..5] of Char;
    FourBitBus: Boolean;
    HighSpeed: Boolean;
  end;

{ Brings up the card in the host's slot (powered and clocked by
  PowerUpCard). False if there is none or it does not answer as an SD
  memory card should; Failure then names the step. }
function InitializeCard(Host: PSdhciHost; out Card: TSdCard; out Failure: PChar): Boolean;
function ReadCardBlocks(Host: PSdhciHost; constref Card: TSdCard; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: PByte): Boolean;
function WriteCardBlocks(Host: PSdhciHost; constref Card: TSdCard; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: PByte): Boolean;
{ "SDHC", "SDXC" or "SDSC". }
function CardKindText(constref Card: TSdCard): PChar;

implementation

uses
  Runtime.Memory,
  Kernel.Scheduler,
  Kernel.Clock,
  Drivers.Sdhci.Registers;

const
  ResponseR1 = CommandResponse48 or CommandCrcCheck or CommandIndexCheck;
  ResponseR1Busy = CommandResponse48Busy or CommandCrcCheck or CommandIndexCheck;
  ResponseR2 = CommandResponse136 or CommandCrcCheck;
  ResponseR3 = CommandResponse48;
  ResponseR6 = ResponseR1;
  ResponseR7 = ResponseR1;

  ReadyTimeoutMilliseconds = 1000;
  { SDXC: more than 32 GiB. }
  SdxcBlocks = QWord(32) * 1024 * 1024 * 2;
  SwitchHighSpeedArgument = LongWord($80FFFFF1);
  SwitchStatusBytes = 64;
  ScrBytes = 8;

{ Bits High..Low of a 136-bit response (CID, CSD) as the card sent them:
  the host keeps bits 127..8 (the CRC dropped) in its four response
  words, shifted down by 8. }
function ResponseBits(constref Words: array of LongWord; High, Low: Integer): LongWord;
var
  Bit: Integer;
  Position: Integer;
begin
  Result := 0;
  Bit := High;
  while Bit >= Low do
  begin
    Position := Bit - 8;
    Result := (Result shl 1) or ((Words[Position div 32] shr (Position mod 32)) and 1);
    Dec(Bit);
  end;
end;

function ApplicationCommand(Host: PSdhciHost; constref Card: TSdCard; Index: Byte; Argument: LongWord;
  ResponseKind: Word): Boolean;
begin
  Result := RunCommand(Host, SdApplicationCommand, Card.Rca shl 16, ResponseR1) and
    RunCommand(Host, Index, Argument, ResponseKind);
end;

{ ACMD41 until the card says it is ready. }
function WaitUntilReady(Host: PSdhciHost; var Card: TSdCard): Boolean;
var
  Argument: LongWord;
  Deadline: QWord;
begin
  Argument := OperatingConditionVoltages;
  if Card.Version2 then
    Argument := Argument or OperatingConditionHighCapacity;
  Deadline := UptimeMilliseconds + ReadyTimeoutMilliseconds;
  repeat
    if not ApplicationCommand(Host, Card, SdAppSendOperatingCondition, Argument, ResponseR3) then
      Exit(False);
    if (Host^.Response[0] and OperatingConditionReady) <> 0 then
    begin
      Card.HighCapacity := (Host^.Response[0] and OperatingConditionHighCapacity) <> 0;
      Exit(True);
    end;
    SleepMilliseconds(10);
  until UptimeMilliseconds > Deadline;
  Result := False;
end;

procedure DecodeCid(var Card: TSdCard);
var
  Index: Integer;
begin
  for Index := 0 to 4 do
    Card.ProductName[Index] := Char(ResponseBits(Card.Cid, 103 - Index * 8, 96 - Index * 8));
  Card.ProductName[5] := #0;
end;

{ The capacity in 512-byte blocks, from CSD version 1 (SDSC) or 2. }
procedure DecodeCsd(var Card: TSdCard);
var
  Size: QWord;
  Multiplier: LongWord;
  ReadBlockLength: LongWord;
begin
  if ResponseBits(Card.Csd, 127, 126) = 1 then
    Card.BlockCount := (QWord(ResponseBits(Card.Csd, 69, 48)) + 1) * 1024
  else
  begin
    Size := ResponseBits(Card.Csd, 73, 62);
    Multiplier := ResponseBits(Card.Csd, 49, 47);
    ReadBlockLength := ResponseBits(Card.Csd, 83, 80);
    Card.BlockCount := ((Size + 1) shl (Multiplier + 2 + ReadBlockLength)) div SdBlockSize;
  end;
end;

{ ACMD6 for a 4-bit bus, where the SCR says the card has one. }
procedure ChooseBusWidth(Host: PSdhciHost; var Card: TSdCard);
const
  ScrFourBitBus = $04;
  BusWidthFour = 2;
begin
  if ((Card.Scr[1] and ScrFourBitBus) <> 0) and
     ApplicationCommand(Host, Card, SdAppSetBusWidth, BusWidthFour, ResponseR1) then
  begin
    SetFourBitBus(Host);
    Card.FourBitBus := True;
  end;
end;

{ CMD6 to high speed, where card and host have it; the clock follows. }
procedure ChooseSpeed(Host: PSdhciHost; var Card: TSdCard);
const
  { The SCR's specification version: 1.10 and later have CMD6. }
  ScrVersion110 = 1;
  { In the switch status (big-endian, 512 bits), bits 379-376: the
    function group 1 chose. }
  GroupOneResultByte = 16;
var
  Status: array[0..SwitchStatusBytes - 1] of Byte;
  HostCanDoIt: Boolean;
begin
  HostCanDoIt := ((Host^.Capabilities and CapabilityHighSpeed) <> 0) or
    ((Host^.Quirks.Flags and QuirkNoHighSpeedBit) <> 0);
  if HostCanDoIt and ((Card.Scr[0] and $F) >= ScrVersion110) and
     RunDataCommand(Host, SdSwitchFunction, SwitchHighSpeedArgument, True, 1, SwitchStatusBytes, @Status[0]) and
     ((Status[GroupOneResultByte] and $F) = 1) then
  begin
    SetHighSpeedTiming(Host);
    Card.HighSpeed := SetCardClock(Host, HighSpeedClockHertz);
    if Card.HighSpeed then
      Exit;
  end;
  SetCardClock(Host, DefaultSpeedClockHertz);
end;

function InitializeCard(Host: PSdhciHost; out Card: TSdCard; out Failure: PChar): Boolean;
var
  Index: Integer;
begin
  Result := False;
  ZeroMemory(@Card, SizeOf(Card));
  Failure := 'reset (CMD0)';
  if not RunCommand(Host, SdGoIdleState, 0, CommandResponseNone) then
    Exit;
  { Version 1 cards do not answer CMD8. }
  Card.Version2 := RunCommand(Host, SdSendInterfaceCondition, InterfaceConditionArgument, ResponseR7);
  Failure := 'interface condition (CMD8)';
  if Card.Version2 and ((Host^.Response[0] and $FFF) <> InterfaceConditionArgument) then
    Exit;
  Failure := 'operating condition (ACMD41): not an SD memory card, or not ready';
  if not WaitUntilReady(Host, Card) then
    Exit;
  Failure := 'identification (CMD2)';
  if not RunCommand(Host, SdAllSendCid, 0, ResponseR2) then
    Exit;
  for Index := 0 to 3 do
    Card.Cid[Index] := Host^.Response[Index];
  DecodeCid(Card);
  Failure := 'relative address (CMD3)';
  if not RunCommand(Host, SdSendRelativeAddress, 0, ResponseR6) then
    Exit;
  Card.Rca := Host^.Response[0] shr 16;
  Failure := 'specific data (CMD9)';
  if not RunCommand(Host, SdSendCsd, Card.Rca shl 16, ResponseR2) then
    Exit;
  for Index := 0 to 3 do
    Card.Csd[Index] := Host^.Response[Index];
  DecodeCsd(Card);
  Failure := 'select (CMD7)';
  if not RunCommand(Host, SdSelectCard, Card.Rca shl 16, ResponseR1Busy) then
    Exit;
  Failure := 'block length (CMD16)';
  if not RunCommand(Host, SdSetBlockLength, SdBlockSize, ResponseR1) then
    Exit;
  { The SCR; a card that cannot give it is taken as 1-bit, version 1.0. }
  if not RunCommand(Host, SdApplicationCommand, Card.Rca shl 16, ResponseR1) or
     not RunDataCommand(Host, SdAppSendScr, 0, True, 1, ScrBytes, @Card.Scr[0]) then
    ZeroMemory(@Card.Scr[0], ScrBytes);
  ChooseBusWidth(Host, Card);
  ChooseSpeed(Host, Card);
  Failure := 'no blocks';
  Result := Card.BlockCount > 0;
end;

function MoveBlocks(Host: PSdhciHost; constref Card: TSdCard; IsWrite: Boolean; FirstBlock: QWord;
  BlockCount: LongWord; Buffer: PByte): Boolean;
var
  Done: LongWord;
  Piece: LongWord;
  Address: QWord;
  Command: Byte;
  Attempt: Integer;
  Moved: Boolean;
begin
  Result := False;
  Done := 0;
  while Done < BlockCount do
  begin
    Piece := BlockCount - Done;
    if Piece > SdhciBounceBytes div SdBlockSize then
      Piece := SdhciBounceBytes div SdBlockSize;
    Address := FirstBlock + Done;
    if not Card.HighCapacity then
      Address := Address * SdBlockSize;
    if Address > High(LongWord) then
      Exit;
    if IsWrite then
    begin
      Command := SdWriteSingleBlock;
      if Piece > 1 then
        Command := SdWriteMultipleBlocks;
    end
    else
    begin
      Command := SdReadSingleBlock;
      if Piece > 1 then
        Command := SdReadMultipleBlocks;
    end;
    Moved := False;
    for Attempt := 1 to 2 do
      if not Moved then
        Moved := RunDataCommand(Host, Command, LongWord(Address), not IsWrite, Piece, SdBlockSize,
          Buffer + QWord(Done) * SdBlockSize);
    if not Moved then
      Exit;
    Done := Done + Piece;
  end;
  Result := True;
end;

function ReadCardBlocks(Host: PSdhciHost; constref Card: TSdCard; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: PByte): Boolean;
begin
  Result := MoveBlocks(Host, Card, False, FirstBlock, BlockCount, Buffer);
end;

function WriteCardBlocks(Host: PSdhciHost; constref Card: TSdCard; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: PByte): Boolean;
begin
  Result := MoveBlocks(Host, Card, True, FirstBlock, BlockCount, Buffer);
end;

function CardKindText(constref Card: TSdCard): PChar;
begin
  if not Card.HighCapacity then
    Result := 'SDSC'
  else if Card.BlockCount > SdxcBlocks then
    Result := 'SDXC'
  else
    Result := 'SDHC';
end;

end.
