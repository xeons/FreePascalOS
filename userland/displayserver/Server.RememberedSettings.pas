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
  What the server keeps in the system's settings (libconfiguration):
  each display's mode and scale, and the mouse's settings the login
  window has.

    Display/N/Mode     "WIDTHxHEIGHT"
    Display/N/Scale    percent
    Mouse/...          the system's mouse settings (Windowing.MouseSettings)

  A display's mode and scale belong to the machine - the screen in front
  of it, whoever logs in - so they are the system's, and the server (which
  runs as root) writes them itself when a program asks it to keep a
  change (DisplayRemember). The mouse's settings are each user's; the
  session manager hands the server a user's when they log in, so the
  server only starts from the system's.

  At start the remembered mode is set first, then the scale, since a new
  mode brings the display's own scale back; for the same reason keeping
  a new mode forgets the scale kept for that display.
}
unit Server.RememberedSettings;

{$mode objfpc}
{$H+}

interface

uses
  Server.Screen;

{ Gives every display its remembered mode and scale, and the mouse the
  system's settings. }
procedure ApplyRememberedSettings;
{ Keeps the screen's present scale, or mode, for the next start. }
procedure RememberScreenScale(Screen: PScreen);
procedure RememberScreenMode(Screen: PScreen);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Format,
  Sys.Streams,
  Configuration.Settings,
  Configuration.Locations,
  Windowing.MouseSettings,
  Server.Modes,
  Server.Scale,
  Server.MouseSettings;

function ScreenPath(Screen: PScreen; const Key: string): string;
begin
  Result := 'Display/' + IntToStr(Screen^.Number) + '/' + Key;
end;

function ParseMode(const Text: string; out Width, Height: LongInt): Boolean;
var
  Separator: Integer;
begin
  Separator := Pos('x', Text);
  Result := (Separator > 1) and TryStrToInt(Copy(Text, 1, Separator - 1), Width) and
    TryStrToInt(Copy(Text, Separator + 1, Length(Text)), Height) and (Width > 0) and (Height > 0);
end;

procedure Say(const Text: string);
begin
  WriteFormatted(StandardOutput, 'displayserver: %s'#10, [ArgumentText(PChar(Text))]);
  FlushStream(StandardOutput);
end;

procedure ApplyScreenSettings(Store: TSettings; Screen: PScreen);
var
  ModeText: string;
  Width: LongInt;
  Height: LongInt;
  Scale: Int64;
begin
  ModeText := Store.ReadString(ScreenPath(Screen, 'Mode'), '');
  if ParseMode(ModeText, Width, Height) then
  begin
    if ChangeMode(Screen, Width, Height) = ErrorNone then
      Say(Format('display %d: remembered mode %dx%d', [Screen^.Number, Width, Height]))
    else
      Say(Format('display %d: the remembered mode %s cannot be set', [Screen^.Number, ModeText]));
  end;
  Scale := Store.ReadInteger(ScreenPath(Screen, 'Scale'), 0);
  if Scale > 0 then
  begin
    ChangeScale(Screen, LongWord(Scale));
    Say(Format('display %d: remembered scale %d%%', [Screen^.Number, Screen^.ScalePercent]));
  end;
end;

procedure ApplyRememberedSettings;
var
  Store: TSettings;
  Index: LongInt;
  Mouse: TMouseSettings;
begin
  Store := OpenSystemSettings;
  for Index := 0 to ScreenCount - 1 do
    ApplyScreenSettings(Store, @Screens[Index]);
  Mouse := RememberedMouseSettings(Store);
  { The server's own (Windowing.MouseSettings has one that asks it). }
  Server.MouseSettings.ChangeMouseSettings(Mouse.Speed, Mouse.Acceleration, Mouse.LeftHanded);
  Store.Free;
end;

procedure FlushAndSay(Store: TSettings; const What: string);
var
  Error: LongInt;
begin
  Error := Store.Flush;
  if Error = ErrorNone then
    Say('remembered ' + What)
  else
    Say(Format('cannot remember %s: error %d', [What, Error]));
end;

procedure RememberScreenScale(Screen: PScreen);
var
  Store: TSettings;
begin
  Store := OpenSystemSettings;
  Store.WriteInteger(ScreenPath(Screen, 'Scale'), Screen^.ScalePercent, ScopeSystem);
  FlushAndSay(Store, Format('display %d: scale %d%%', [Screen^.Number, Screen^.ScalePercent]));
  Store.Free;
end;

procedure RememberScreenMode(Screen: PScreen);
var
  Store: TSettings;
begin
  Store := OpenSystemSettings;
  Store.WriteString(ScreenPath(Screen, 'Mode'), Format('%dx%d', [Screen^.Device.Width, Screen^.Device.Height]),
    ScopeSystem);
  Store.Delete(ScreenPath(Screen, 'Scale'), ScopeSystem);
  FlushAndSay(Store, Format('display %d: mode %dx%d', [Screen^.Number, Screen^.Device.Width,
    Screen^.Device.Height]));
  Store.Free;
end;

end.
