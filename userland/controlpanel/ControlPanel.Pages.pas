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
  What every page of the Control Panel is: a panel on the right of the
  window, under a heading, that shows the settings as they are now
  (Load) and makes the changes chosen on it (Apply).

  A page tells the window when something on it was changed (Modified),
  so Apply can be pressed; Apply and OK apply every page that was
  changed, Cancel forgets the changes. A page whose changes are made at
  once, in dialogs of their own (the users), never says it is modified.
  Sizes are logical units: PageWidth x PageHeight.
}
unit ControlPanel.Pages;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Panels;

const
  PageWidth = 456;
  PageHeight = 352;
  { Inside the page's frame. }
  PageMargin = 14;
  RowHeight = 22;
  LabelWidth = 130;

type
  TSettingsPage = class(TGroupBox)
  private
    FWindow: TControlWindow;
    FModified: Boolean;
    FLoading: Boolean;
    FOnModified: TControlEvent;
  protected
    { Puts the settings as they are now into the page's controls (their
      changes meanwhile do not count as the user's). }
    procedure LoadSettings; virtual; abstract;
    { Something on the page was changed by the user. }
    procedure MarkModified;
    { A control's change marks the page modified (hook OnChange). }
    procedure ControlChanged(Sender: TControl);
  public
    constructor CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string); virtual;
    { The page's name on the command line and in the output ("display"). }
    function PageName: string; virtual; abstract;
    { Shows the settings as they are now; not modified any more. }
    procedure Load;
    { Makes the changes; False (after saying why) if they could not be
      made, the page staying modified. }
    function Apply: Boolean; virtual;
    { Says where the page's controls are on the screen. }
    procedure TellPlaces; virtual;
    { The page became the one shown. }
    procedure Shown; virtual;
    property Window: TControlWindow read FWindow;
    property Modified: Boolean read FModified write FModified;
    property OnModified: TControlEvent read FOnModified write FOnModified;
  end;

implementation

constructor TSettingsPage.CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string);
begin
  inherited Create(AParent);
  FWindow := AWindow;
  Text := ATitle;
end;

procedure TSettingsPage.Load;
begin
  FLoading := True;
  try
    LoadSettings;
  finally
    FLoading := False;
  end;
  FModified := False;
end;

procedure TSettingsPage.MarkModified;
begin
  if FLoading then
    Exit;
  FModified := True;
  if Assigned(FOnModified) then
    FOnModified(Self);
end;

procedure TSettingsPage.ControlChanged(Sender: TControl);
begin
  MarkModified;
end;

function TSettingsPage.Apply: Boolean;
begin
  FModified := False;
  Result := True;
end;

procedure TSettingsPage.TellPlaces;
begin
end;

procedure TSettingsPage.Shown;
begin
end;

end.
