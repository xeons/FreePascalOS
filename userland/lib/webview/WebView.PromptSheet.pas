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
  A page's alert, confirm, prompt and "leave this page?" as a sheet
  across the top of its own view: modal for that tab only. The page
  waits for the answer (its content process does), while the browser
  and its other tabs go on. OK (Enter) or Cancel (Escape) answers,
  through OnAnswered, and the view removes the sheet.
}
unit WebView.PromptSheet;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Panels,
  Controls.Labels,
  Controls.Buttons,
  Controls.EditBox;

type
  TPromptSheet = class;
  TPromptAnsweredEvent = procedure(Sheet: TPromptSheet; Accepted: Boolean; const Text: string) of object;

  TPromptSheetKind = (SheetAlert, SheetConfirm, SheetPrompt, SheetLeavePage);

  TPromptSheet = class(TPanel)
  private
    FKind: TPromptSheetKind;
    FMessage: TLabel;
    FEdit: TEditBox;
    FOkButton: TButton;
    FCancelButton: TButton;
    FOnAnswered: TPromptAnsweredEvent;
    FAnswered: Boolean;
    procedure OkClicked(Sender: TControl);
    procedure CancelClicked(Sender: TControl);
    procedure Answer(Accepted: Boolean);
  protected
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    constructor CreateSheet(AParent: TControl; AKind: TPromptSheetKind; const Origin, Message, Default: string);
    { Puts the keyboard on the sheet (its box or its OK button). }
    procedure TakeFocus;
    property Kind: TPromptSheetKind read FKind;
    property OnAnswered: TPromptAnsweredEvent read FOnAnswered write FOnAnswered;
  end;

implementation

uses
  Controls.Keys;

const
  SheetPadding = 8;
  LineHeight = 20;
  ButtonWidth = 80;
  ButtonHeight = 24;

constructor TPromptSheet.CreateSheet(AParent: TControl; AKind: TPromptSheetKind; const Origin, Message, Default: string);
var
  Height, Top: LongInt;
  Title: TLabel;
begin
  inherited Create(AParent);
  FKind := AKind;
  Edge := PanelRaised;
  Align := AlignTop;
  Height := SheetPadding * 3 + LineHeight * 2 + ButtonHeight;
  if AKind = SheetPrompt then
    Inc(Height, LineHeight + SheetPadding);
  SetBounds(0, 0, 400, Height);
  Title := TLabel.Create(Self);
  Title.ShowsMnemonic := False;
  if AKind = SheetLeavePage then
    Title.Text := 'This page asks you to confirm that you want to leave'
  else
    Title.Text := Origin + ' says:';
  Title.SetBounds(SheetPadding, SheetPadding, 380, LineHeight);
  Title.Anchors := [akLeft, akTop, akRight];
  FMessage := TLabel.Create(Self);
  FMessage.ShowsMnemonic := False;
  FMessage.Text := Message;
  FMessage.SetBounds(SheetPadding, SheetPadding + LineHeight, 380, LineHeight);
  FMessage.Anchors := [akLeft, akTop, akRight];
  Top := SheetPadding * 2 + LineHeight * 2;
  if AKind = SheetPrompt then
  begin
    FEdit := TEditBox.Create(Self);
    FEdit.Text := Default;
    FEdit.SetBounds(SheetPadding, Top, 380, LineHeight + 2);
    FEdit.Anchors := [akLeft, akTop, akRight];
    Inc(Top, LineHeight + SheetPadding);
  end;
  FOkButton := TButton.Create(Self);
  if AKind = SheetLeavePage then
    FOkButton.Text := '&Leave'
  else
    FOkButton.Text := 'OK';
  FOkButton.OnClick := @OkClicked;
  FOkButton.SetBounds(SheetPadding, Top, ButtonWidth, ButtonHeight);
  if AKind <> SheetAlert then
  begin
    FCancelButton := TButton.Create(Self);
    if AKind = SheetLeavePage then
      FCancelButton.Text := '&Stay'
    else
      FCancelButton.Text := 'Cancel';
    FCancelButton.OnClick := @CancelClicked;
    FCancelButton.SetBounds(SheetPadding * 2 + ButtonWidth, Top, ButtonWidth, ButtonHeight);
  end;
end;

procedure TPromptSheet.TakeFocus;
begin
  if FEdit <> nil then
    FEdit.SetFocus
  else
    FOkButton.SetFocus;
end;

procedure TPromptSheet.Answer(Accepted: Boolean);
var
  Typed: string;
begin
  if FAnswered then
    Exit;
  FAnswered := True;
  Typed := '';
  if FEdit <> nil then
    Typed := FEdit.Text;
  if Assigned(FOnAnswered) then
    FOnAnswered(Self, Accepted, Typed);
end;

procedure TPromptSheet.OkClicked(Sender: TControl);
begin
  Answer(True);
end;

procedure TPromptSheet.CancelClicked(Sender: TControl);
begin
  Answer(FKind = SheetAlert);
end;

function TPromptSheet.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  if IsEnterKey(Code) then
  begin
    Answer(True);
    Exit(True);
  end;
  if Code = KeyEscape then
  begin
    Answer(FKind = SheetAlert);
    Exit(True);
  end;
  Result := inherited KeyDown(Code, Character, Modifiers);
end;

end.
