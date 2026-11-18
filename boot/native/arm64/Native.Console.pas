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
  Text output of the native boot stub: the console UART the device tree
  names (stdout-path), written at its physical address with the MMU
  off, the line set up as the firmware left it. Without one the stub is
  silent.
}
unit Native.Console;

{$mode objfpc}

interface

uses
  DeviceTree.Chosen;

procedure AttachConsole(constref Uart: TDeviceTreeUart);
procedure PrintText(Text: PChar);
procedure PrintLine(Text: PChar);
procedure PrintHexadecimal(Value: QWord);
procedure PrintDecimal(Value: QWord);

implementation

uses
  Runtime.Text;

const
  Pl011Data = $00;
  Pl011Flags = $18;
  Pl011FlagTransmitFull = $20;
  Uart16550Data = 0;
  Uart16550LineStatus = 5;
  LineStatusTransmitterEmpty = $20;
  MaximumTransmitWaitIterations = 100000;

var
  Console: TDeviceTreeUart;
  Attached: Boolean = False;

procedure AttachConsole(constref Uart: TDeviceTreeUart);
begin
  Console := Uart;
  Attached := Uart.Kind <> DeviceTreeUartNone;
end;

function Read16550(Index: LongWord): LongWord;
var
  Address: QWord;
begin
  Address := Console.PhysicalAddress + (QWord(Index) shl Console.RegisterShift);
  if Console.RegisterWidth = 4 then
    Result := PLongWord(Address)^
  else
    Result := PByte(Address)^;
end;

procedure Write16550(Index: LongWord; Value: LongWord);
var
  Address: QWord;
begin
  Address := Console.PhysicalAddress + (QWord(Index) shl Console.RegisterShift);
  if Console.RegisterWidth = 4 then
    PLongWord(Address)^ := Value
  else
    PByte(Address)^ := Byte(Value);
end;

procedure WriteCharacter(Character: Char);
var
  Iteration: LongWord;
begin
  Iteration := 0;
  case Console.Kind of
    DeviceTreeUartPl011:
      begin
        while ((PLongWord(Console.PhysicalAddress + Pl011Flags)^ and Pl011FlagTransmitFull) <> 0) and
              (Iteration < MaximumTransmitWaitIterations) do
          Inc(Iteration);
        PLongWord(Console.PhysicalAddress + Pl011Data)^ := Ord(Character);
      end;
    DeviceTreeUart16550:
      begin
        while ((Read16550(Uart16550LineStatus) and LineStatusTransmitterEmpty) = 0) and
              (Iteration < MaximumTransmitWaitIterations) do
          Inc(Iteration);
        Write16550(Uart16550Data, Ord(Character));
      end;
  end;
end;

procedure PrintText(Text: PChar);
begin
  if not Attached or (Text = nil) then
    Exit;
  while Text^ <> #0 do
  begin
    if Text^ = #10 then
      WriteCharacter(#13);
    WriteCharacter(Text^);
    Inc(Text);
  end;
end;

procedure PrintLine(Text: PChar);
begin
  PrintText(Text);
  PrintText(#10);
end;

procedure PrintHexadecimal(Value: QWord);
var
  Buffer: TNumberText;
begin
  PrintText('0x');
  PrintText(FormatHexadecimal(Value, 1, Buffer));
end;

procedure PrintDecimal(Value: QWord);
var
  Buffer: TNumberText;
begin
  PrintText(FormatDecimal(Value, Buffer));
end;

end.
