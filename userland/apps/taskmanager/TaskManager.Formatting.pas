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
  How the task manager writes its numbers: sizes in KB, MB or GB with
  one decimal where it helps, shares in percent, times as hours,
  minutes and seconds, users by name.
}
unit TaskManager.Formatting;

{$mode objfpc}
{$H+}

interface

{ "512 KB", "12.3 MB", "1.5 GB" (powers of 1024). }
function FormatBytes(Bytes: QWord): string;
{ Tenths of a percent as a whole percent: "37%". }
function FormatPercent(Tenths: LongWord): string;
{ "0:03:25", or with days "2d 4:05:00". }
function FormatDuration(Seconds: QWord): string;
{ Processor time in nanoseconds as a duration. }
function FormatProcessorTime(Nanoseconds: QWord): string;
{ The user's name, or the number if there is no such account. }
function UserName(UserId: LongWord): string;

implementation

uses
  SysUtils,
  Util.Accounts;

const
  Kibibyte = 1024;
  Mebibyte = 1024 * 1024;
  Gibibyte = 1024 * 1024 * 1024;

{ Value / Unit with one decimal, rounded. }
function WithOneDecimal(Value, UnitBytes: QWord): string;
var
  Tenths: QWord;
begin
  Tenths := (Value * 10 + UnitBytes div 2) div UnitBytes;
  Result := IntToStr(Tenths div 10) + '.' + IntToStr(Tenths mod 10);
end;

function FormatBytes(Bytes: QWord): string;
begin
  if Bytes >= Gibibyte then
    Result := WithOneDecimal(Bytes, Gibibyte) + ' GB'
  else if Bytes >= 10 * Mebibyte then
    Result := IntToStr((Bytes + Mebibyte div 2) div Mebibyte) + ' MB'
  else if Bytes >= Mebibyte then
    Result := WithOneDecimal(Bytes, Mebibyte) + ' MB'
  else
    Result := IntToStr((Bytes + Kibibyte div 2) div Kibibyte) + ' KB';
end;

function FormatPercent(Tenths: LongWord): string;
begin
  Result := IntToStr((Tenths + 5) div 10) + '%';
end;

function FormatDuration(Seconds: QWord): string;
var
  Days: QWord;
begin
  Days := Seconds div 86400;
  Seconds := Seconds mod 86400;
  Result := Format('%d:%.2d:%.2d', [Seconds div 3600, (Seconds div 60) mod 60, Seconds mod 60]);
  if Days > 0 then
    Result := IntToStr(Days) + 'd ' + Result;
end;

function FormatProcessorTime(Nanoseconds: QWord): string;
begin
  Result := FormatDuration(Nanoseconds div 1000000000);
end;

function UserName(UserId: LongWord): string;
begin
  Result := UserNameOrNumber(UserId);
end;

end.
