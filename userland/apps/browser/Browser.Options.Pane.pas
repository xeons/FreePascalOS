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
  What every pane of the Options window has (Browser.Options.*): its
  page, the settings it shows (Load) and takes back (Store), and helpers
  that place group boxes, check boxes, radio buttons, labels, edit boxes,
  buttons and lists in logical units, a row at a time.
}
unit Browser.Options.Pane;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Controls.Base,
  Controls.Panels,
  Controls.Labels,
  Controls.EditBox,
  Controls.Buttons,
  Controls.Toggles,
  Controls.ComboBox,
  Browser.Settings;

const
  PaneWidth = 560;
  PaneMargin = 10;
  RowHeight = 24;
  GroupTop = 26;

type
  TOptionsPane = class
  protected
    FPage: TControl;
    FOwner: TWindow;
  public
    constructor Create(Page: TControl; Owner: TWindow); virtual;
    procedure Build; virtual; abstract;
    procedure Load(constref Settings: TBrowserSettings); virtual; abstract;
    procedure Store(var Settings: TBrowserSettings); virtual; abstract;
    { A group box across the page at Top, Height high. }
    function AddGroup(const Caption: string; Top, Height: LongInt): TGroupBox;
    { The same inside Parent (a tab's page). }
    function AddGroupIn(Parent: TControl; const Caption: string; Top, Height: LongInt): TGroupBox;
    { A borderless panel inside Parent (radio buttons that go together). }
    function AddRadioPanel(Parent: TControl; Left, Top, Width, Height: LongInt): TPanel;
    function AddCheck(Parent: TControl; const Caption: string; Left, Top: LongInt; Width: LongInt = 0): TCheckBox;
    function AddRadio(Parent: TControl; const Caption: string; Left, Top: LongInt; Width: LongInt = 0): TRadioButton;
    function AddLabel(Parent: TControl; const Caption: string; Left, Top: LongInt; Width: LongInt = 0): TLabel;
    function AddEdit(Parent: TControl; Left, Top, Width: LongInt): TEditBox;
    function AddButton(Parent: TControl; const Caption: string; Left, Top: LongInt; Width: LongInt = 0;
      Handler: TControlEvent = nil): TButton;
    function AddCombo(Parent: TControl; const Items: array of string; Left, Top, Width: LongInt): TComboBox;
    property Page: TControl read FPage;
    property Owner: TWindow read FOwner;
  end;

  TOptionsPaneClass = class of TOptionsPane;

implementation

uses
  Controls.Text,
  Controls.LayoutRules;

constructor TOptionsPane.Create(Page: TControl; Owner: TWindow);
begin
  inherited Create;
  FPage := Page;
  FOwner := Owner;
end;

function TOptionsPane.AddGroup(const Caption: string; Top, Height: LongInt): TGroupBox;
begin
  Result := TGroupBox.Create(FPage);
  Result.Text := Caption;
  Result.SetBounds(PaneMargin, Top, PaneWidth - 2 * PaneMargin, Height);
  Result.Anchors := [akLeft, akTop, akRight];
end;

function TOptionsPane.AddGroupIn(Parent: TControl; const Caption: string; Top, Height: LongInt): TGroupBox;
begin
  Result := TGroupBox.Create(Parent);
  Result.Text := Caption;
  Result.SetBounds(8, Top, PaneWidth - 2 * PaneMargin - 20, Height);
  Result.Anchors := [akLeft, akTop, akRight];
end;

function TOptionsPane.AddRadioPanel(Parent: TControl; Left, Top, Width, Height: LongInt): TPanel;
begin
  Result := TPanel.Create(Parent);
  Result.Edge := PanelFlat;
  Result.SetBounds(Left, Top, Width, Height);
end;

function CaptionWidth(const Caption: string; Width: LongInt): LongInt;
begin
  if Width > 0 then
    Result := Width
  else
    Result := PixelsToLogicalCeiling(MnemonicTextWidth(ControlFace, Caption)) + 30;
end;

function TOptionsPane.AddCheck(Parent: TControl; const Caption: string; Left, Top: LongInt; Width: LongInt): TCheckBox;
begin
  Result := TCheckBox.Create(Parent);
  Result.Text := Caption;
  Result.SetBounds(Left, Top, CaptionWidth(Caption, Width), 20);
end;

function TOptionsPane.AddRadio(Parent: TControl; const Caption: string; Left, Top: LongInt;
  Width: LongInt): TRadioButton;
begin
  Result := TRadioButton.Create(Parent);
  Result.Text := Caption;
  Result.SetBounds(Left, Top, CaptionWidth(Caption, Width), 20);
end;

function TOptionsPane.AddLabel(Parent: TControl; const Caption: string; Left, Top: LongInt; Width: LongInt): TLabel;
begin
  Result := TLabel.Create(Parent);
  Result.Text := Caption;
  if Width <= 0 then
    Width := CaptionWidth(Caption, 0) - 24;
  Result.SetBounds(Left, Top + 3, Width, 18);
end;

function TOptionsPane.AddEdit(Parent: TControl; Left, Top, Width: LongInt): TEditBox;
begin
  Result := TEditBox.Create(Parent);
  Result.SetBounds(Left, Top, Width, 22);
end;

function TOptionsPane.AddButton(Parent: TControl; const Caption: string; Left, Top: LongInt; Width: LongInt;
  Handler: TControlEvent): TButton;
begin
  Result := TButton.Create(Parent);
  Result.Text := Caption;
  if Width <= 0 then
    Width := PixelsToLogicalCeiling(MnemonicTextWidth(ControlFace, Caption)) + 24;
  Result.SetBounds(Left, Top, Width, 23);
  Result.OnClick := Handler;
end;

function TOptionsPane.AddCombo(Parent: TControl; const Items: array of string; Left, Top, Width: LongInt): TComboBox;
var
  Index: Integer;
begin
  Result := TComboBox.Create(Parent);
  for Index := 0 to High(Items) do
    Result.Items.Add(Items[Index]);
  Result.ItemIndex := 0;
  Result.SetBounds(Left, Top, Width, 22);
end;

end.
