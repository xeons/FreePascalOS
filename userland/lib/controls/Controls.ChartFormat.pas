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
  How a chart writes its values: on the axes' ticks, in the tooltip and
  on a pie's slices.

  Every format takes the step between the ticks, so the labels of one
  axis share their number of decimals ("0.5", "1.0", "1.5"); a value
  shown alone (a tooltip) passes 0 and gets what it needs. Numbers use
  a point for the decimals and no thousands separators. Sizes in bytes
  are in powers of 1024 (B, KiB, MiB, GiB, TiB), a duration in seconds
  reads "45 s", "2 min", "1 min 30 s", "3 h".
}
unit Controls.ChartFormat;

{$mode objfpc}
{$H+}

interface

type
  TChartValueFormat = (
    ChartFormatNumber,
    { The value is already in percent: "25%". }
    ChartFormatPercent,
    ChartFormatBytes,
    { Seconds. }
    ChartFormatDuration
  );

function FormatChartNumber(Value, Step: Double): string;
function FormatChartPercent(Value, Step: Double): string;
function FormatChartBytes(Value, Step: Double): string;
function FormatChartDuration(Value, Step: Double): string;
function FormatChartValue(Format: TChartValueFormat; Value, Step: Double): string;
{ A share of a whole (0 to 1) as a whole percent, or with one decimal
  under 10%: "34%", "2.5%". }
function FormatShare(Share: Double): string;

implementation

uses
  SysUtils,
  Math,
  Controls.ChartScale;

const
  { Decimals for a value shown alone. }
  AloneDecimals = 2;
  MostByteDecimals = 2;
  ByteUnits: array[0..4] of string = ('B', 'KiB', 'MiB', 'GiB', 'TiB');

function PointFormat: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

{ Value with Decimals decimals; "-0" becomes "0". }
function WithDecimals(Value: Double; Decimals: LongInt): string;
begin
  Result := FloatToStrF(Value, ffFixed, 18, Decimals, PointFormat);
  if (Length(Result) > 1) and (Result[1] = '-') and (StrToFloat(Copy(Result, 2, MaxInt), PointFormat) = 0) then
    Delete(Result, 1, 1);
end;

{ "1.50" to "1.5", "2.00" to "2". }
function WithoutTrailingZeros(const Text: string): string;
begin
  Result := Text;
  if Pos('.', Result) = 0 then
    Exit;
  while Result[Length(Result)] = '0' do
    Delete(Result, Length(Result), 1);
  if Result[Length(Result)] = '.' then
    Delete(Result, Length(Result), 1);
end;

function FormatChartNumber(Value, Step: Double): string;
begin
  if Step > 0 then
    Result := WithDecimals(Value, DecimalsForStep(Step))
  else
    Result := WithoutTrailingZeros(WithDecimals(Value, AloneDecimals));
end;

function FormatChartPercent(Value, Step: Double): string;
begin
  Result := FormatChartNumber(Value, Step) + '%';
end;

function FormatChartBytes(Value, Step: Double): string;
var
  UnitIndex: LongInt;
  UnitSize: Double;
  Decimals: LongInt;
begin
  if Value = 0 then
    Exit('0 B');
  { The unit is the value's own (1536 is "1.5 KiB"). }
  UnitIndex := 0;
  UnitSize := 1;
  while (UnitIndex < High(ByteUnits)) and (Abs(Value) >= UnitSize * 1024) do
  begin
    Inc(UnitIndex);
    UnitSize := UnitSize * 1024;
  end;
  if Step > 0 then
    Decimals := Min(DecimalsForStep(Step / UnitSize), MostByteDecimals)
  else
    Decimals := 1;
  if UnitIndex = 0 then
    Decimals := 0;
  Result := WithoutTrailingZeros(WithDecimals(Value / UnitSize, Decimals)) + ' ' + ByteUnits[UnitIndex];
end;

function FormatChartDuration(Value, Step: Double): string;
var
  Seconds: Int64;
  Sign: string;
begin
  Sign := '';
  if Value < 0 then
  begin
    Sign := '-';
    Value := -Value;
  end;
  { Under a minute, or a step finer than a second: in seconds. }
  if (Value < 60) or ((Step > 0) and (Step < 1)) then
    Exit(Sign + FormatChartNumber(Value, Step) + ' s');
  Seconds := Round(Value);
  if Seconds < 3600 then
  begin
    if Seconds mod 60 = 0 then
      Result := IntToStr(Seconds div 60) + ' min'
    else
      Result := IntToStr(Seconds div 60) + ' min ' + IntToStr(Seconds mod 60) + ' s';
  end
  else if Seconds mod 3600 = 0 then
    Result := IntToStr(Seconds div 3600) + ' h'
  else
    Result := IntToStr(Seconds div 3600) + ' h ' + IntToStr((Seconds mod 3600) div 60) + ' min';
  Result := Sign + Result;
end;

function FormatChartValue(Format: TChartValueFormat; Value, Step: Double): string;
begin
  case Format of
    ChartFormatPercent: Result := FormatChartPercent(Value, Step);
    ChartFormatBytes: Result := FormatChartBytes(Value, Step);
    ChartFormatDuration: Result := FormatChartDuration(Value, Step);
  else
    Result := FormatChartNumber(Value, Step);
  end;
end;

function FormatShare(Share: Double): string;
var
  Percent: Double;
begin
  Percent := Share * 100;
  if (Percent > 0) and (Percent < 10) then
    Result := WithoutTrailingZeros(WithDecimals(Percent, 1)) + '%'
  else
    Result := WithDecimals(Percent, 0) + '%';
end;

end.
