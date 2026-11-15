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
  HID report descriptors: where a pointing device puts its axes and
  buttons in the reports it sends.

  A report descriptor is a list of items. Global items (usage page,
  logical minimum and maximum, report size, count and id) stay in force
  until changed; local items (usages, usage ranges) apply to the next
  main item only. An Input main item lays out Report Count fields of
  Report Size bits each, one after another, each taking the next usage;
  its flags say whether they are constant (padding), variable and
  relative or absolute.

  ParsePointerLayout looks for a report holding the Generic Desktop X
  and Y usages and notes where X, Y, the wheel and the first buttons
  are in it. ReadHidField takes a field's value out of a report.
}
unit Drivers.HidReports;

{$mode objfpc}
{$pointermath on}

interface

const
  MaximumPointerButtons = 5;

type
  THidField = record
    Present: Boolean;
    BitOffset: LongWord;
    BitSize: LongWord;
    LogicalMinimum: LongInt;
    LogicalMaximum: LongInt;
    Relative: Boolean;
  end;

  THidPointerLayout = record
    { Reports start with their id byte if the descriptor uses ids. }
    UsesReportIds: Boolean;
    ReportId: Byte;
    X: THidField;
    Y: THidField;
    Wheel: THidField;
    Buttons: array[1..MaximumPointerButtons] of THidField;
  end;

function ParsePointerLayout(Data: PByte; Length: LongWord; out Layout: THidPointerLayout): Boolean;
{ Field's value in Report (whose first byte is the id, if ids are used),
  sign extended if its logical minimum is negative. 0 if the report is
  too short. }
function ReadHidField(const Layout: THidPointerLayout; const Field: THidField; Report: PByte;
  ReportLength: LongWord): LongInt;

implementation

uses
  Runtime.Memory;

const
  ItemTypeMain = 0;
  ItemTypeGlobal = 1;
  ItemTypeLocal = 2;
  LongItemPrefix = $FE;

  MainInput = $8;
  GlobalUsagePage = $0;
  GlobalLogicalMinimum = $1;
  GlobalLogicalMaximum = $2;
  GlobalReportSize = $7;
  GlobalReportId = $8;
  GlobalReportCount = $9;
  GlobalPush = $A;
  GlobalPop = $B;
  LocalUsage = $0;
  LocalUsageMinimum = $1;
  LocalUsageMaximum = $2;

  InputConstant = $01;
  InputVariable = $02;
  InputRelative = $04;

  PageGenericDesktop = $01;
  PageButton = $09;
  UsageX = $30;
  UsageY = $31;
  UsageWheel = $38;

  MaximumUsages = 32;
  MaximumStackDepth = 4;
  { Reports a descriptor may describe (by id): kept small, the parser
    runs on kernel stacks. }
  MaximumReports = 8;

type
  TGlobals = record
    UsagePage: LongWord;
    LogicalMinimum: LongInt;
    LogicalMaximum: LongInt;
    ReportSize: LongWord;
    ReportId: Byte;
    ReportCount: LongWord;
  end;

  { One report's fields as found (the pointer's report is picked after). }
  TReportFields = record
    Id: Byte;
    BitOffset: LongWord;
    Layout: THidPointerLayout;
    HasX: Boolean;
    HasY: Boolean;
  end;

  TReportTable = record
    Reports: array[0..MaximumReports - 1] of TReportFields;
    Count: Integer;
  end;

{ The report with Id, added if new; nil if the table is full. }
function ReportWithId(var Table: TReportTable; Id: Byte): Pointer;
var
  Index: Integer;
begin
  for Index := 0 to Table.Count - 1 do
    if Table.Reports[Index].Id = Id then
      Exit(@Table.Reports[Index]);
  if Table.Count = MaximumReports then
    Exit(nil);
  ZeroMemory(@Table.Reports[Table.Count], SizeOf(TReportFields));
  Table.Reports[Table.Count].Id := Id;
  Result := @Table.Reports[Table.Count];
  Inc(Table.Count);
end;

{ The item's data, unsigned and sign extended. }
procedure ItemData(Data: PByte; Size: Integer; out Unsigned: LongWord; out Signed: LongInt);
begin
  Unsigned := 0;
  Signed := 0;
  case Size of
    1:
      begin
        Unsigned := Data[0];
        Signed := ShortInt(Data[0]);
      end;
    2:
      begin
        Unsigned := Data[0] or (LongWord(Data[1]) shl 8);
        Signed := SmallInt(Unsigned);
      end;
    4:
      begin
        Unsigned := Data[0] or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16) or (LongWord(Data[3]) shl 24);
        Signed := LongInt(Unsigned);
      end;
  end;
end;

function ParsePointerLayout(Data: PByte; Length: LongWord; out Layout: THidPointerLayout): Boolean;
var
  Globals: TGlobals;
  Stack: array[0..MaximumStackDepth - 1] of TGlobals;
  Depth: Integer;
  Usages: array[0..MaximumUsages - 1] of LongWord;
  UsageCount: Integer;
  UsageMinimum: LongWord;
  UsageMaximum: LongWord;
  HasUsageRange: Boolean;
  Table: TReportTable;
  Position: LongWord;
  Prefix: Byte;
  Size: Integer;
  ItemType: Integer;
  Tag: Integer;
  Unsigned: LongWord;
  Signed: LongInt;
  Index: LongWord;
  Usage: LongWord;
  Field: THidField;
  Report: ^TReportFields;
  Button: LongWord;
  UsesIds: Boolean;
  Index2: Integer;
begin
  Result := False;
  ZeroMemory(@Layout, SizeOf(Layout));
  ZeroMemory(@Globals, SizeOf(Globals));
  Table.Count := 0;
  Depth := 0;
  UsageCount := 0;
  HasUsageRange := False;
  UsageMinimum := 0;
  UsageMaximum := 0;
  UsesIds := False;
  Position := 0;
  while Position < Length do
  begin
    Prefix := Data[Position];
    if Prefix = LongItemPrefix then
    begin
      { Long items: skipped (their size is in the next byte). }
      if Position + 1 >= Length then
        Break;
      Position := Position + 3 + Data[Position + 1];
      Continue;
    end;
    Size := Prefix and 3;
    if Size = 3 then
      Size := 4;
    if Position + 1 + LongWord(Size) > Length then
      Break;
    ItemType := (Prefix shr 2) and 3;
    Tag := Prefix shr 4;
    ItemData(Data + Position + 1, Size, Unsigned, Signed);
    case ItemType of
      ItemTypeGlobal:
        case Tag of
          GlobalUsagePage: Globals.UsagePage := Unsigned;
          GlobalLogicalMinimum: Globals.LogicalMinimum := Signed;
          GlobalLogicalMaximum:
            { A maximum read as negative with a non-negative minimum is a
              large unsigned value. }
            if (Signed < 0) and (Globals.LogicalMinimum >= 0) then
              Globals.LogicalMaximum := LongInt(Unsigned)
            else
              Globals.LogicalMaximum := Signed;
          GlobalReportSize: Globals.ReportSize := Unsigned;
          GlobalReportId:
            begin
              Globals.ReportId := Byte(Unsigned);
              UsesIds := True;
            end;
          GlobalReportCount: Globals.ReportCount := Unsigned;
          GlobalPush:
            if Depth < MaximumStackDepth then
            begin
              Stack[Depth] := Globals;
              Inc(Depth);
            end;
          GlobalPop:
            if Depth > 0 then
            begin
              Dec(Depth);
              Globals := Stack[Depth];
            end;
        end;
      ItemTypeLocal:
        case Tag of
          LocalUsage:
            if UsageCount < MaximumUsages then
            begin
              { A short usage takes the current page. }
              if Size <= 2 then
                Unsigned := Unsigned or (Globals.UsagePage shl 16);
              Usages[UsageCount] := Unsigned;
              Inc(UsageCount);
            end;
          LocalUsageMinimum:
            begin
              UsageMinimum := Unsigned;
              if Size <= 2 then
                UsageMinimum := UsageMinimum or (Globals.UsagePage shl 16);
              HasUsageRange := True;
            end;
          LocalUsageMaximum:
            begin
              UsageMaximum := Unsigned;
              if Size <= 2 then
                UsageMaximum := UsageMaximum or (Globals.UsagePage shl 16);
            end;
        end;
      ItemTypeMain:
        begin
          if Tag = MainInput then
          begin
            Report := ReportWithId(Table, Globals.ReportId);
            if (Report <> nil) and (Globals.ReportCount > 0) then
              for Index := 0 to Globals.ReportCount - 1 do
              begin
                if (Unsigned and InputConstant) = 0 then
                begin
                  if Index < LongWord(UsageCount) then
                    Usage := Usages[Index]
                  else if HasUsageRange and (UsageMinimum + Index <= UsageMaximum) then
                    Usage := UsageMinimum + Index
                  else if UsageCount > 0 then
                    Usage := Usages[UsageCount - 1]
                  else
                    Usage := 0;
                  Field.Present := True;
                  Field.BitOffset := Report^.BitOffset;
                  Field.BitSize := Globals.ReportSize;
                  Field.LogicalMinimum := Globals.LogicalMinimum;
                  Field.LogicalMaximum := Globals.LogicalMaximum;
                  Field.Relative := (Unsigned and InputRelative) <> 0;
                  if (Unsigned and InputVariable) <> 0 then
                    if Usage = (PageGenericDesktop shl 16) or UsageX then
                    begin
                      Report^.Layout.X := Field;
                      Report^.HasX := True;
                    end
                    else if Usage = (PageGenericDesktop shl 16) or UsageY then
                    begin
                      Report^.Layout.Y := Field;
                      Report^.HasY := True;
                    end
                    else if Usage = (PageGenericDesktop shl 16) or UsageWheel then
                      Report^.Layout.Wheel := Field
                    else if (Usage shr 16) = PageButton then
                    begin
                      Button := Usage and $FFFF;
                      if (Button >= 1) and (Button <= MaximumPointerButtons) then
                        Report^.Layout.Buttons[Button] := Field;
                    end;
                end;
                Report^.BitOffset := Report^.BitOffset + Globals.ReportSize;
              end;
          end;
          { Local items end with every main item. }
          UsageCount := 0;
          HasUsageRange := False;
        end;
    end;
    Position := Position + 1 + LongWord(Size);
  end;
  for Index2 := 0 to Table.Count - 1 do
    if Table.Reports[Index2].HasX and Table.Reports[Index2].HasY then
    begin
      Layout := Table.Reports[Index2].Layout;
      Layout.UsesReportIds := UsesIds;
      Layout.ReportId := Table.Reports[Index2].Id;
      Exit(True);
    end;
end;

function ReadHidField(const Layout: THidPointerLayout; const Field: THidField; Report: PByte;
  ReportLength: LongWord): LongInt;
var
  Bit: LongWord;
  Start: LongWord;
  Value: LongWord;
  Index: LongWord;
begin
  Result := 0;
  if not Field.Present or (Field.BitSize = 0) or (Field.BitSize > 32) then
    Exit;
  Start := Field.BitOffset;
  if Layout.UsesReportIds then
    Start := Start + 8;
  if (Start + Field.BitSize + 7) div 8 > ReportLength then
    Exit;
  Value := 0;
  for Index := 0 to Field.BitSize - 1 do
  begin
    Bit := Start + Index;
    if (Report[Bit div 8] and (1 shl (Bit mod 8))) <> 0 then
      Value := Value or (LongWord(1) shl Index);
  end;
  if (Field.LogicalMinimum < 0) and (Field.BitSize < 32) and ((Value and (LongWord(1) shl (Field.BitSize - 1))) <> 0) then
    Value := Value or not ((LongWord(1) shl Field.BitSize) - 1);
  Result := LongInt(Value);
end;

end.
