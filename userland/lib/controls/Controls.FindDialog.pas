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
  The find and replace dialogs: what to look for, whether case matters,
  and which way to go (find) or what to put instead (replace).

  The dialog stays open while the user finds one match after another:
  its buttons do not end it but tell the program (OnFindNext, OnReplace,
  OnReplaceAll), which searches its own text (a multi-line edit box's
  FindText, ReplaceNext and ReplaceAll, say) and can tell the user it
  found nothing in a message box owned by the dialog. Cancel, Escape or
  the close button end it. Enter in either box presses Find Next. It is
  modal, like every dialog here: the window it searches is disabled
  meanwhile, though it still shows each match as it is selected.
}
unit Controls.FindDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Controls.Base,
  Controls.EditBox,
  Controls.Toggles,
  Controls.Buttons,
  Controls.Dialogs,
  Controls.TextSearch;

type
  TFindDialog = class;
  TFindDialogEvent = procedure(Dialog: TFindDialog) of object;

  TFindDialog = class(TDialog)
  private
    FReplacing: Boolean;
    FFindEdit: TEditBox;
    FReplaceEdit: TEditBox;
    FMatchCaseBox: TCheckBox;
    FUpButton: TRadioButton;
    FDownButton: TRadioButton;
    FFindNextButton: TButton;
    FOnFindNext: TFindDialogEvent;
    FOnReplace: TFindDialogEvent;
    FOnReplaceAll: TFindDialogEvent;
    procedure BuildControls;
    function AddCommandButton(const Caption: string; Top: LongInt; Handler: TControlEvent): TButton;
    procedure FindNextClicked(Sender: TControl);
    procedure ReplaceClicked(Sender: TControl);
    procedure ReplaceAllClicked(Sender: TControl);
    function GetFindText: string;
    procedure SetFindText(const Value: string);
    function GetReplaceText: string;
    procedure SetReplaceText(const Value: string);
    function GetMatchCase: Boolean;
    procedure SetMatchCase(Value: Boolean);
    function GetDirection: TSearchDirection;
    procedure SetDirection(Value: TSearchDirection);
  public
    { Replacing: the replace dialog (else the find dialog). AOwner: the
      window searched. }
    constructor CreateFindDialog(const ATitle: string; Replacing: Boolean; AOwner: TWindow);
    { Shows it until it is closed (the text to find selected). }
    procedure Execute;
    { The options as Controls.TextSearch takes them (always down when
      replacing). }
    function Options: TSearchOptions;
    property FindText: string read GetFindText write SetFindText;
    property ReplaceText: string read GetReplaceText write SetReplaceText;
    property MatchCase: Boolean read GetMatchCase write SetMatchCase;
    property Direction: TSearchDirection read GetDirection write SetDirection;
    property Replacing: Boolean read FReplacing;
    property FindEdit: TEditBox read FFindEdit;
    property ReplaceEdit: TEditBox read FReplaceEdit;
    property OnFindNext: TFindDialogEvent read FOnFindNext write FOnFindNext;
    property OnReplace: TFindDialogEvent read FOnReplace write FOnReplace;
    property OnReplaceAll: TFindDialogEvent read FOnReplaceAll write FOnReplaceAll;
  end;

implementation

uses
  Controls.Labels,
  Controls.Panels,
  Controls.CommonDialogs;

const
  DialogWidth = 360;
  FindDialogHeight = 104;
  ReplaceDialogHeight = 132;
  LabelWidth = 80;
  FieldLeft = 92;
  FieldWidth = 172;
  FieldHeight = 22;
  ButtonLeft = 276;
  ButtonStep = 28;

constructor TFindDialog.CreateFindDialog(const ATitle: string; Replacing: Boolean; AOwner: TWindow);
var
  Height: LongInt;
begin
  if Replacing then
    Height := ReplaceDialogHeight
  else
    Height := FindDialogHeight;
  inherited CreateDialog(ATitle, DialogWidth, Height, AOwner);
  FReplacing := Replacing;
  BuildControls;
end;

function TFindDialog.AddCommandButton(const Caption: string; Top: LongInt; Handler: TControlEvent): TButton;
begin
  Result := TButton.Create(Root);
  Result.Text := Caption;
  Result.SetBounds(ButtonLeft, Top, DialogButtonWidth, DialogButtonHeight);
  Result.OnClick := Handler;
end;

procedure TFindDialog.BuildControls;
var
  Caption: TLabel;
  DirectionBox: TGroupBox;
  OptionsTop: LongInt;
  ButtonTop: LongInt;
begin
  Caption := TLabel.Create(Root);
  Caption.Text := 'Fi&nd what:';
  Caption.SetBounds(DialogMargin, DialogMargin + 3, LabelWidth, 16);
  FFindEdit := TEditBox.Create(Root);
  FFindEdit.SetBounds(FieldLeft, DialogMargin, FieldWidth, FieldHeight);
  OptionsTop := DialogMargin + FieldHeight + 12;
  if FReplacing then
  begin
    Caption := TLabel.Create(Root);
    Caption.Text := 'Re&place with:';
    Caption.SetBounds(DialogMargin, OptionsTop + 3, LabelWidth, 16);
    FReplaceEdit := TEditBox.Create(Root);
    FReplaceEdit.SetBounds(FieldLeft, OptionsTop, FieldWidth, FieldHeight);
    OptionsTop := OptionsTop + FieldHeight + 12;
  end;
  FMatchCaseBox := TCheckBox.Create(Root);
  FMatchCaseBox.Text := 'Match &case';
  FMatchCaseBox.SetBounds(DialogMargin, OptionsTop + 20, 100, 20);
  if not FReplacing then
  begin
    DirectionBox := TGroupBox.Create(Root);
    DirectionBox.Text := 'Direction';
    DirectionBox.SetBounds(FieldLeft + 32, OptionsTop, FieldWidth - 32, 44);
    FUpButton := TRadioButton.Create(DirectionBox);
    FUpButton.Text := '&Up';
    FUpButton.SetBounds(8, 18, 56, 20);
    FDownButton := TRadioButton.Create(DirectionBox);
    FDownButton.Text := '&Down';
    FDownButton.SetBounds(68, 18, 64, 20);
    FDownButton.Checked := True;
  end;
  ButtonTop := DialogMargin;
  FFindNextButton := AddCommandButton('&Find Next', ButtonTop, @FindNextClicked);
  FFindNextButton.IsDefault := True;
  DefaultControl := FFindNextButton;
  if FReplacing then
  begin
    ButtonTop := ButtonTop + ButtonStep;
    AddCommandButton('&Replace', ButtonTop, @ReplaceClicked);
    ButtonTop := ButtonTop + ButtonStep;
    AddCommandButton('Replace &All', ButtonTop, @ReplaceAllClicked);
  end;
  ButtonTop := ButtonTop + ButtonStep;
  AddButton('Cancel', ResultCancel, ButtonLeft, ButtonTop, DialogButtonWidth, DialogButtonHeight, False, True);
end;

procedure TFindDialog.Execute;
begin
  FocusControl(FFindEdit);
  FFindEdit.SelectAll;
  ShowModal;
end;

procedure TFindDialog.FindNextClicked(Sender: TControl);
begin
  if (FindText <> '') and Assigned(FOnFindNext) then
    FOnFindNext(Self);
end;

procedure TFindDialog.ReplaceClicked(Sender: TControl);
begin
  if (FindText <> '') and Assigned(FOnReplace) then
    FOnReplace(Self);
end;

procedure TFindDialog.ReplaceAllClicked(Sender: TControl);
begin
  if (FindText <> '') and Assigned(FOnReplaceAll) then
    FOnReplaceAll(Self);
end;

function TFindDialog.Options: TSearchOptions;
begin
  Result := MakeSearchOptions(MatchCase, Direction);
end;

function TFindDialog.GetFindText: string;
begin
  Result := FFindEdit.Text;
end;

procedure TFindDialog.SetFindText(const Value: string);
begin
  FFindEdit.Text := Value;
end;

function TFindDialog.GetReplaceText: string;
begin
  if FReplaceEdit = nil then
    Exit('');
  Result := FReplaceEdit.Text;
end;

procedure TFindDialog.SetReplaceText(const Value: string);
begin
  if FReplaceEdit <> nil then
    FReplaceEdit.Text := Value;
end;

function TFindDialog.GetMatchCase: Boolean;
begin
  Result := FMatchCaseBox.Checked;
end;

procedure TFindDialog.SetMatchCase(Value: Boolean);
begin
  FMatchCaseBox.Checked := Value;
end;

function TFindDialog.GetDirection: TSearchDirection;
begin
  if (FUpButton <> nil) and FUpButton.Checked then
    Result := SearchUp
  else
    Result := SearchDown;
end;

procedure TFindDialog.SetDirection(Value: TSearchDirection);
begin
  if FUpButton = nil then
    Exit;
  FUpButton.Checked := Value = SearchUp;
  FDownButton.Checked := Value = SearchDown;
end;

end.
