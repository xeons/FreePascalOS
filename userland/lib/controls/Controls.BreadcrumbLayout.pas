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
  What a breadcrumb bar (Controls.BreadcrumbBar) shows, as plain logic:
  which of the path's segments fit, the rest collapsing from the left
  into an overflow button, and the path of a folder's child.

  Plain logic, no system calls: it builds for the host too and is
  checked there (tools/NavigationControlsTest).
}
unit Controls.BreadcrumbLayout;

{$mode objfpc}
{$H+}

interface

{ The first segment shown when segments of Widths (pixels, each with its
  chevron) share Available pixels: those from it to the last fit, with
  OverflowWidth more for the overflow button if any are left out. The
  last segment always shows (cut short if it must be). }
function FirstShownSegment(const Widths: array of LongInt; Available, OverflowWidth: LongInt): LongInt;
{ Name inside the folder Path: "/" and "a" give "/a", "/a" and "b"
  give "/a/b" (one slash between them, whether Path ends in one or not). }
function JoinChildPath(const Path, Name: string): string;

implementation

function FirstShownSegment(const Widths: array of LongInt; Available, OverflowWidth: LongInt): LongInt;
var
  Total: LongInt;
  Index: LongInt;
begin
  if Length(Widths) = 0 then
    Exit(0);
  Total := 0;
  for Index := 0 to High(Widths) do
    Total := Total + Widths[Index];
  if Total <= Available then
    Exit(0);
  { Some are hidden: room for the overflow button, then from the last
    segment back as many as fit. }
  Result := High(Widths);
  Total := OverflowWidth + Widths[Result];
  while (Result > 0) and (Total + Widths[Result - 1] <= Available) do
  begin
    Dec(Result);
    Total := Total + Widths[Result];
  end;
end;

function JoinChildPath(const Path, Name: string): string;
begin
  if Path = '' then
    Exit(Name);
  if Path[Length(Path)] = '/' then
    Result := Path + Name
  else
    Result := Path + '/' + Name;
end;

end.
