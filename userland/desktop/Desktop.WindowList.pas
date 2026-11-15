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
  The other programs' top-level windows, as the display server tells the
  shell about them (EventShellWindowChanged, EventShellWindowGone): each
  one's number, title, state and display, in the order they appeared,
  which is the order of the taskbar's buttons. Each change is said on
  the standard output ("task N STATE TITLE", "task-gone N"), and
  OnChange lets the taskbar follow.
}
unit Desktop.WindowList;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Protocol;

type
  TTaskWindow = record
    Id: LongWord;
    Title: string;
    { ShellWindow* (Windowing.Protocol). }
    Flags: LongWord;
    DisplayNumber: LongInt;
  end;

  TWindowListEvent = procedure of object;

  TWindowList = class
  private
    FWindows: array of TTaskWindow;
    FOnChange: TWindowListEvent;
    function GetCount: LongInt;
    function GetWindow(Index: LongInt): TTaskWindow;
    procedure Changed;
  public
    { Takes an EventShellWindowChanged. }
    procedure TakeChange(const Message: TWindowMessage);
    procedure Remove(Id: LongWord);
    function IndexOf(Id: LongWord): LongInt;
    { Whether window Index has a button: shown, or minimized. }
    function HasButton(Index: LongInt): Boolean;
    property Count: LongInt read GetCount;
    property Windows[Index: LongInt]: TTaskWindow read GetWindow; default;
    property OnChange: TWindowListEvent read FOnChange write FOnChange;
  end;

{ The state words "task" lines use: minimized, active, shown, hidden. }
function StateName(Flags: LongWord): string;

implementation

uses
  SysUtils,
  Desktop.Report;

function StateName(Flags: LongWord): string;
begin
  if (Flags and ShellWindowMinimized) <> 0 then
    Result := 'minimized'
  else if (Flags and ShellWindowVisible) = 0 then
    Result := 'hidden'
  else if (Flags and ShellWindowActive) <> 0 then
    Result := 'active'
  else
    Result := 'shown';
end;

function TWindowList.GetCount: LongInt;
begin
  Result := Length(FWindows);
end;

function TWindowList.GetWindow(Index: LongInt): TTaskWindow;
begin
  Result := FWindows[Index];
end;

function TWindowList.IndexOf(Id: LongWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(FWindows) do
    if FWindows[Index].Id = Id then
      Exit(Index);
  Result := -1;
end;

function TWindowList.HasButton(Index: LongInt): Boolean;
begin
  Result := (FWindows[Index].Flags and (ShellWindowVisible or ShellWindowMinimized)) <> 0;
end;

procedure TWindowList.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange();
end;

procedure TWindowList.TakeChange(const Message: TWindowMessage);
var
  Index: LongInt;
begin
  Index := IndexOf(Message.Window);
  if Index < 0 then
  begin
    Index := Length(FWindows);
    SetLength(FWindows, Index + 1);
    FWindows[Index].Id := Message.Window;
  end;
  FWindows[Index].Title := StrPas(@Message.Text[0]);
  FWindows[Index].Flags := Message.Flags;
  FWindows[Index].DisplayNumber := LongInt(Message.Code);
  Say(Format('task %u %s %s', [Message.Window, StateName(Message.Flags), FWindows[Index].Title]));
  Changed;
end;

procedure TWindowList.Remove(Id: LongWord);
var
  Index: LongInt;
begin
  Index := IndexOf(Id);
  if Index < 0 then
    Exit;
  while Index < High(FWindows) do
  begin
    FWindows[Index] := FWindows[Index + 1];
    Inc(Index);
  end;
  SetLength(FWindows, Length(FWindows) - 1);
  Say(Format('task-gone %u', [Id]));
  Changed;
end;

end.
