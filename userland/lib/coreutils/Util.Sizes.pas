{
  Sizes for people: 1536 -> "1.5K", 3221225472 -> "3.0G" (powers of
  1024, as ls -h and df -h print them), and parsing of sizes with
  suffixes such as "10K" or "2M" (head -c, truncate -s).
}
unit Util.Sizes;

{$mode objfpc}
{$pointermath on}

interface

{ Writes into Buffer (at least 16 characters) and returns it. }
function FormatHumanSize(Size: QWord; Buffer: PChar): PChar;
{ Accepts a decimal number with an optional suffix K, M, G, T (powers of
  1024) or KB, MB, GB, TB (powers of 1000). }
function ParseSize(Text: PChar; out Size: QWord): Boolean;

implementation

uses
  Runtime.Text,
  Sys.Text;

function FormatHumanSize(Size: QWord; Buffer: PChar): PChar;
const
  Units: array[0..6] of Char = ('B', 'K', 'M', 'G', 'T', 'P', 'E');
var
  UnitIndex: Integer;
  Tenths: QWord;
  Divisor: QWord;
  NumberText: TNumberText;
  Position: PtrUInt;
begin
  if Size < 1024 then
  begin
    CopyText(Buffer, FormatDecimal(Size, NumberText), 16);
    Exit(Buffer);
  end;

  UnitIndex := 0;
  Divisor := 1;
  while (Size div Divisor >= 1024) and (UnitIndex < 6) do
  begin
    Divisor := Divisor * 1024;
    Inc(UnitIndex);
  end;
  { Round up, as GNU tools do, to one decimal below 10 and to whole
    numbers above. }
  Tenths := (Size * 10 + Divisor - 1) div Divisor;
  if Tenths >= 100 then
  begin
    CopyText(Buffer, FormatDecimal((Tenths + 9) div 10, NumberText), 16);
    Position := TextLength(Buffer);
  end
  else
  begin
    CopyText(Buffer, FormatDecimal(Tenths div 10, NumberText), 16);
    Position := TextLength(Buffer);
    Buffer[Position] := '.';
    Buffer[Position + 1] := Char(Ord('0') + Tenths mod 10);
    Position := Position + 2;
  end;
  Buffer[Position] := Units[UnitIndex];
  Buffer[Position + 1] := #0;
  Result := Buffer;
end;

function ParseSize(Text: PChar; out Size: QWord): Boolean;
var
  Digits: array[0..31] of Char;
  Length: PtrUInt;
  Multiplier: QWord;
  Base: QWord;
  Value: QWord;
  SuffixStart: PtrUInt;
begin
  Size := 0;
  Length := TextLength(Text);
  SuffixStart := 0;
  while (SuffixStart < Length) and IsDigit(Text[SuffixStart]) do
    Inc(SuffixStart);
  if (SuffixStart = 0) or (SuffixStart >= SizeOf(Digits)) then
    Exit(False);
  CopyText(@Digits[0], Text, SuffixStart + 1);
  if not ParseUnsigned(@Digits[0], Value) then
    Exit(False);

  Multiplier := 1;
  if SuffixStart < Length then
  begin
    Base := 1024;
    if (Length = SuffixStart + 2) and (ToUpperCase(Text[SuffixStart + 1]) = 'B') then
      Base := 1000
    else if Length <> SuffixStart + 1 then
      Exit(False);
    case ToUpperCase(Text[SuffixStart]) of
      'K': Multiplier := Base;
      'M': Multiplier := Base * Base;
      'G': Multiplier := Base * Base * Base;
      'T': Multiplier := Base * Base * Base * Base;
    else
      Exit(False);
    end;
  end;
  Size := Value * Multiplier;
  Result := True;
end;

end.
