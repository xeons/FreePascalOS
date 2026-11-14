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
  Classes for FreePascalOS: the generic Free Pascal Classes unit
  (rtl/objpas/classes). TThread is the portable one of the Unix RTL
  (tthread.inc), which needs nothing but the thread manager of System.
}
{$mode objfpc}
{$H+}
{ Classes declares and starts TThread the Unix way when UNIX is defined,
  which is the model tthread.inc implements; nothing else in the unit
  depends on it. }
{$define UNIX}
unit Classes;

{$inline on}

interface

uses
  SysUtils,
  Types,
  TypInfo,
  RtlConsts;

{$i classesh.inc}

implementation

{$i classes.inc}

initialization
  CommonInit;
finalization
  CommonCleanup;
  if ThreadsInited then
    DoneThreads;
end.
