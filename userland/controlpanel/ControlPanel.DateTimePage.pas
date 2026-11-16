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
  The Date and Time page: the time now, in the system's zone; the time
  zone, from the database (Sys.TimeZones, each with its offset now);
  and the date and time, to set the clock.

  The date and time boxes follow the clock until one is edited; what is
  typed is a local time of the zone chosen above. Both changes are
  root's: applying sends them to the system settings service as an
  administrator (ControlPanel.Administrator asks for the password once).
}
unit ControlPanel.DateTimePage;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.ListBox,
  Controls.EditBox,
  Sys.TimeZones,
  ControlPanel.Pages;

type
  TDateTimePage = class(TSettingsPage)
  private
    FNow: TLabel;
    FZones: TListBox;
    FDateBox: TEditBox;
    FTimeBox: TEditBox;
    FLoadedZone: PTimeZone;
    FClockEdited: Boolean;
    FFillingClock: Boolean;
    procedure ClockEdited(Sender: TControl);
    procedure ShowNow;
    procedure FillClockBoxes;
    function ChosenZone: PTimeZone;
    function ApplyZone(Zone: PTimeZone): Boolean;
    function ApplyClock(Zone: PTimeZone): Boolean;
  protected
    procedure LoadSettings; override;
  public
    constructor CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string); override;
    function PageName: string; override;
    function Apply: Boolean; override;
    procedure TellPlaces; override;
    { Every second: the time shown moves on. }
    procedure Tick; override;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Runtime.Time,
  Sys.Time,
  Sys.LocalTime,
  Sys.SystemSettings,
  Windowing.Connection,
  Controls.MessageBoxes,
  ControlPanel.Administrator,
  ControlPanel.Report;

const
  ControlLeft = PageMargin + LabelWidth;

function OffsetText(Offset: LongInt): string;
var
  Buffer: array[0..7] of Char;
begin
  FormatUtcOffset(Offset, @Buffer[0]);
  { +0100 as UTC+01:00, as people read it. }
  Result := 'UTC' + Buffer[0] + Buffer[1] + Buffer[2] + ':' + Buffer[3] + Buffer[4];
end;

constructor TDateTimePage.CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string);
var
  Caption: TLabel;
  Index: LongInt;
  Zone: PTimeZone;
begin
  inherited CreatePage(AParent, AWindow, ATitle);
  FNow := TLabel.Create(Self);
  FNow.ShowsMnemonic := False;
  FNow.SetBounds(PageMargin, 28, PageWidth - 2 * PageMargin, 18);
  Caption := TLabel.Create(Self);
  Caption.Text := 'Time &zone:';
  Caption.SetBounds(PageMargin, 62, LabelWidth - 6, 18);
  FZones := TListBox.Create(Self);
  FZones.SetBounds(ControlLeft, 60, PageWidth - ControlLeft - PageMargin, 170);
  for Index := 0 to TimeZoneCount - 1 do
  begin
    Zone := TimeZoneAt(Index);
    FZones.Items.Add(Format('%s  (%s)', [Zone^.Name, OffsetText(ZoneOffsetAt(Zone, CurrentTime).Offset)]));
  end;
  FZones.OnChange := @ControlChanged;
  Caption := TLabel.Create(Self);
  Caption.Text := '&Date:';
  Caption.SetBounds(PageMargin, 246, LabelWidth - 6, 18);
  FDateBox := TEditBox.Create(Self);
  FDateBox.SetBounds(ControlLeft, 244, 110, 22);
  FDateBox.OnChange := @ClockEdited;
  Caption := TLabel.Create(Self);
  Caption.Text := 'T&ime:';
  Caption.SetBounds(ControlLeft + 124, 246, 40, 18);
  FTimeBox := TEditBox.Create(Self);
  FTimeBox.SetBounds(ControlLeft + 166, 244, 90, 22);
  FTimeBox.OnChange := @ClockEdited;
  Caption := TLabel.Create(Self);
  Caption.ShowsMnemonic := False;
  Caption.Text := 'YYYY-MM-DD and HH:MM:SS, local time.';
  Caption.SetBounds(ControlLeft, 272, PageWidth - ControlLeft - PageMargin, 18);
end;

function TDateTimePage.PageName: string;
begin
  Result := 'datetime';
end;

function TDateTimePage.ChosenZone: PTimeZone;
begin
  Result := TimeZoneAt(FZones.ItemIndex);
  if Result = nil then
    Result := SystemTimeZone;
end;

procedure TDateTimePage.ShowNow;
var
  Local: TLocalTime;
  Moment: TDateTime;
begin
  DecodeTimeInZone(SystemTimeZone, CurrentTime, Local);
  Moment := Local.DateTime;
  FNow.Text := Format('%s %.4d-%.2d-%.2d %.2d:%.2d:%.2d %s (%s)', [DayName(Moment.DayOfWeek), Moment.Year,
    Moment.Month, Moment.Day, Moment.Hour, Moment.Minute, Moment.Second, Local.Abbreviation,
    OffsetText(Local.Offset)]);
end;

procedure TDateTimePage.FillClockBoxes;
var
  Local: TLocalTime;
begin
  DecodeTimeInZone(ChosenZone, CurrentTime, Local);
  FFillingClock := True;
  FDateBox.Text := Format('%.4d-%.2d-%.2d', [Local.DateTime.Year, Local.DateTime.Month, Local.DateTime.Day]);
  FTimeBox.Text := Format('%.2d:%.2d:%.2d', [Local.DateTime.Hour, Local.DateTime.Minute, Local.DateTime.Second]);
  FFillingClock := False;
end;

procedure TDateTimePage.ClockEdited(Sender: TControl);
begin
  if FFillingClock then
    Exit;
  FClockEdited := True;
  MarkModified;
end;

procedure TDateTimePage.Tick;
begin
  ShowNow;
  if not FClockEdited and not FDateBox.Focused and not FTimeBox.Focused then
    FillClockBoxes;
end;

procedure TDateTimePage.LoadSettings;
var
  Index: LongInt;
begin
  FLoadedZone := SystemTimeZone;
  for Index := 0 to TimeZoneCount - 1 do
    if TimeZoneAt(Index) = FLoadedZone then
      FZones.ItemIndex := Index;
  FClockEdited := False;
  ShowNow;
  FillClockBoxes;
end;

function TDateTimePage.ApplyZone(Zone: PTimeZone): Boolean;
var
  Request: TSystemSettingsRequest;
  Error: LongInt;
begin
  Request := NewSystemSettingsRequest(SystemRequestSetTimeZone);
  SetRequestText(@Request.Text[0], SystemTextCapacity, Zone^.Name);
  Error := SendAsAdministrator(Window, Request);
  Result := Error = ErrorNone;
  if Result then
  begin
    FLoadedZone := Zone;
    Say('applied time-zone ' + string(Zone^.Name));
  end
  else if Error <> ErrorInterrupted then
    ShowMessageBox('Date and Time', 'The time zone could not be changed. ' + RefusalText(Error), MessageOk,
      SignError, Window);
end;

{ Reads YYYY-MM-DD and HH:MM:SS (or HH:MM). }
function ReadClockBoxes(const DateText, TimeText: string; out Year, Month, Day, Hour, Minute, Second: LongInt): Boolean;
begin
  Result := (Length(DateText) = 10) and (DateText[5] = '-') and (DateText[8] = '-') and
    TryStrToInt(Copy(DateText, 1, 4), Year) and TryStrToInt(Copy(DateText, 6, 2), Month) and
    TryStrToInt(Copy(DateText, 9, 2), Day) and (Length(TimeText) >= 5) and (TimeText[3] = ':') and
    TryStrToInt(Copy(TimeText, 1, 2), Hour) and TryStrToInt(Copy(TimeText, 4, 2), Minute);
  Second := 0;
  if Result and (Length(TimeText) = 8) then
    Result := (TimeText[6] = ':') and TryStrToInt(Copy(TimeText, 7, 2), Second)
  else if Result then
    Result := Length(TimeText) = 5;
  Result := Result and (Month >= 1) and (Month <= 12) and (Day >= 1) and (Day <= 31) and (Hour >= 0) and
    (Hour <= 23) and (Minute >= 0) and (Minute <= 59) and (Second >= 0) and (Second <= 59);
end;

function TDateTimePage.ApplyClock(Zone: PTimeZone): Boolean;
var
  Year, Month, Day, Hour, Minute, Second: LongInt;
  Request: TSystemSettingsRequest;
  Error: LongInt;
begin
  Result := ReadClockBoxes(Trim(FDateBox.Text), Trim(FTimeBox.Text), Year, Month, Day, Hour, Minute, Second);
  if not Result then
  begin
    ShowMessageBox('Date and Time', 'Write the date as YYYY-MM-DD and the time as HH:MM:SS.', MessageOk, SignWarning,
      Window);
    Exit;
  end;
  Request := NewSystemSettingsRequest(SystemRequestSetClock);
  Request.Time := ZoneLocalTimeToUnixTime(Zone, Year, Month, Day, Hour, Minute, Second);
  Error := SendAsAdministrator(Window, Request);
  Result := Error = ErrorNone;
  if Result then
  begin
    FClockEdited := False;
    Say(Format('applied clock %.4d-%.2d-%.2d %.2d:%.2d:%.2d', [Year, Month, Day, Hour, Minute, Second]));
  end
  else if Error <> ErrorInterrupted then
    ShowMessageBox('Date and Time', 'The date and time could not be set. ' + RefusalText(Error), MessageOk,
      SignError, Window);
end;

function TDateTimePage.Apply: Boolean;
var
  Zone: PTimeZone;
begin
  Result := True;
  Zone := ChosenZone;
  if Zone <> FLoadedZone then
    Result := ApplyZone(Zone);
  if Result and FClockEdited then
    Result := ApplyClock(Zone);
  if Result then
  begin
    inherited Apply;
    ShowNow;
    FillClockBoxes;
  end;
end;

procedure TDateTimePage.TellPlaces;
begin
  SayControlPlace('datetime-zones', Window, FZones);
  SayControlPlace('datetime-date', Window, FDateBox);
  SayControlPlace('datetime-time', Window, FTimeBox);
end;

end.
