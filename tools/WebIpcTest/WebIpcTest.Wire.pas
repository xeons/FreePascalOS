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

{ WebIpcTest: the wire format (WebIpc.Wire). }
unit WebIpcTest.Wire;

{$mode objfpc}
{$H+}

interface

procedure RunWireChecks;

implementation

uses
  SysUtils,
  TestChecks,
  WebIpc.Wire;

procedure CheckEveryTypeBothWays;
var
  Writer: TIpcWriter;
  Reader: TIpcReader;
  Data, Bytes: TBytes;
  List: TStringArray;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteByte($AB);
    Writer.WriteBoolean(True);
    Writer.WriteBoolean(False);
    Writer.WriteWord($BEEF);
    Writer.WriteLongWord($DEADBEEF);
    Writer.WriteLongInt(-123456);
    Writer.WriteQWord(QWord($0123456789ABCDEF));
    Writer.WriteInt64(-9876543210);
    Writer.WriteDouble(3.25);
    Writer.WriteString('hello, ' + #$C3#$A9 + 't' + #$C3#$A9);
    Writer.WriteString('');
    Bytes := nil;
    SetLength(Bytes, 3);
    Bytes[0] := 1;
    Bytes[1] := 0;
    Bytes[2] := 255;
    Writer.WriteBytes(Bytes);
    Writer.WriteStrings(['one', '', 'three']);
    Data := Writer.Data;
  finally
    Writer.Free;
  end;
  Check(Length(Data) = 1 + 2 + 2 + 4 + 4 + 8 + 8 + 8 + (4 + 12) + 4 + (4 + 3) + (4 + 7 + 4 + 9), 'wire: the length');
  CheckBytes(@Data[3], 6, 'efbeefbeadde', 'wire: little-endian integers');
  Reader := TIpcReader.Create(Data);
  try
    Check(Reader.ReadByte = $AB, 'wire: a byte');
    Check(Reader.ReadBoolean and not Reader.ReadBoolean, 'wire: booleans');
    Check(Reader.ReadWord = $BEEF, 'wire: a word');
    Check(Reader.ReadLongWord = $DEADBEEF, 'wire: a long word');
    Check(Reader.ReadLongInt = -123456, 'wire: a negative long int');
    Check(Reader.ReadQWord = QWord($0123456789ABCDEF), 'wire: a quad word');
    Check(Reader.ReadInt64 = -9876543210, 'wire: a negative int64');
    Check(Reader.ReadDouble = 3.25, 'wire: a double');
    Check(Reader.ReadString = 'hello, ' + #$C3#$A9 + 't' + #$C3#$A9, 'wire: a UTF-8 string');
    Check(Reader.ReadString = '', 'wire: an empty string');
    Bytes := Reader.ReadBytes;
    Check((Length(Bytes) = 3) and (Bytes[0] = 1) and (Bytes[1] = 0) and (Bytes[2] = 255), 'wire: bytes');
    List := Reader.ReadStrings;
    Check((Length(List) = 3) and (List[0] = 'one') and (List[1] = '') and (List[2] = 'three'), 'wire: a list of strings');
    Check(Reader.Remaining = 0, 'wire: everything read');
  finally
    Reader.Free;
  end;
end;

function RefusesToRead(const Data: TBytes; What: Integer): Boolean;
var
  Reader: TIpcReader;
begin
  Result := False;
  Reader := TIpcReader.Create(Data);
  try
    try
      case What of
        0: Reader.ReadLongWord;
        1: Reader.ReadString;
        2: Reader.ReadBytes;
        3: Reader.ReadStrings;
        4: Reader.ReadDouble;
      end;
    except
      on EIpcMalformed do
        Result := True;
    end;
  finally
    Reader.Free;
  end;
end;

procedure CheckMalformedRefused;
var
  Data: TBytes;
begin
  Data := nil;
  SetLength(Data, 3);
  Check(RefusesToRead(Data, 0), 'wire: a long word cut short is refused');
  Check(RefusesToRead(Data, 4), 'wire: a double cut short is refused');
  SetLength(Data, 6);
  { A string claiming 2^32-1 bytes, with two there. }
  Data[0] := $FF;
  Data[1] := $FF;
  Data[2] := $FF;
  Data[3] := $FF;
  Check(RefusesToRead(Data, 1), 'wire: a string claiming more than is there is refused');
  Check(RefusesToRead(Data, 2), 'wire: bytes claiming more than is there are refused');
  Check(RefusesToRead(Data, 3), 'wire: a list claiming more than is there is refused');
  Data[0] := 3;
  Data[1] := 0;
  Data[2] := 0;
  Data[3] := 0;
  Check(RefusesToRead(Data, 1), 'wire: a string one byte short is refused');
end;

procedure RunWireChecks;
begin
  CheckEveryTypeBothWays;
  CheckMalformedRefused;
end;

end.
