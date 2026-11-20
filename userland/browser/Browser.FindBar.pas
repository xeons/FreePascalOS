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
  The find bar under the page (Ctrl+F): what to find, Previous and
  Next, Match case, what was found, and a close button. Typing finds as
  it goes; Enter finds the next match, Shift+Enter the one before,
  Escape closes the bar. The window does the finding (OnFind).
}
unit Browser.FindBar;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Panels,
  Controls.Labels,
  Controls.EditBox,
  Controls.Buttons,
  Controls.Toggles;

type
  TFindEvent = procedure(const Text: string; Forward, MatchCase, FromStart: Boolean) of object;

  TFindBar = class(TPanel)
  private
    FCaption: TLabel;
    FEdit: TEditBox;
    FPrevious: TButton;
    FNext: TButton;
    FMatchCase: TCheckBox;
    FStatus: TLabel;
    FClose: TButton;
    FOnFind: TFindEvent;
    FOnClosed: TControlEvent;
    procedure EditChanged(Sender: TControl);
    procedure EditKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure PreviousClicked(Sender: TControl);
    procedure NextClicked(Sender: TControl);
    procedure CloseClicked(Sender: TControl);
    procedure Find(Forward, FromStart: Boolean);
  public
    constructor Create(AParent: TControl); override;
    { Shows the bar with the focus in its box, the text selected. }
    procedure Open;
    procedure Close;
    { "3 found" or "Not found". }
    procedure ShowResult(Found: Boolean);
    function PreferredSize: TSize; override;
    property Edit: TEditBox read FEdit;
    property OnFind: TFindEvent read FOnFind write FOnFind;
    property OnClosed: TControlEvent read FOnClosed write FOnClosed;
  end;

implementation

uses
  Abi.SystemCalls,
  Controls.Keys,
  Controls.LayoutRules,
  Controls.Window;

const
  BarHeight = 32;

function Spaced(Control: TControl; Left, Right: LongInt): TControl;
begin
  Control.Margins := MakeSpacing(Left, 5, Right, 5);
  Result := Control;
end;

constructor TFindBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  Edge := PanelRaised;
  FCaption := TLabel.Create(Self);
  FCaption.Text := 'Find:';
  FCaption.AutoSize := True;
  FCaption.Align := AlignLeft;
  Spaced(FCaption, 8, 4).Margins := MakeSpacing(8, 8, 4, 5);
  FEdit := TEditBox.Create(Self);
  FEdit.SetBounds(0, 0, 220, 22);
  FEdit.Align := AlignLeft;
  Spaced(FEdit, 2, 4);
  FEdit.OnChange := @EditChanged;
  FEdit.OnKeyDown := @EditKey;
  FPrevious := TButton.Create(Self);
  FPrevious.Text := '&Previous';
  FPrevious.AutoSize := True;
  FPrevious.Align := AlignLeft;
  Spaced(FPrevious, 2, 2);
  FPrevious.OnClick := @PreviousClicked;
  FNext := TButton.Create(Self);
  FNext.Text := '&Next';
  FNext.AutoSize := True;
  FNext.Align := AlignLeft;
  Spaced(FNext, 2, 8);
  FNext.OnClick := @NextClicked;
  FMatchCase := TCheckBox.Create(Self);
  FMatchCase.Text := 'Match &case';
  FMatchCase.AutoSize := True;
  FMatchCase.Align := AlignLeft;
  Spaced(FMatchCase, 4, 8);
  FClose := TButton.Create(Self);
  FClose.Text := 'Close';
  FClose.AutoSize := True;
  FClose.Flat := True;
  FClose.Align := AlignRight;
  Spaced(FClose, 4, 6);
  FClose.OnClick := @CloseClicked;
  FStatus := TLabel.Create(Self);
  FStatus.Align := AlignClient;
  FStatus.Margins := MakeSpacing(4, 8, 4, 5);
  Visible := False;
end;

function TFindBar.PreferredSize: TSize;
begin
  Result.Width := 400;
  Result.Height := BarHeight;
end;

procedure TFindBar.Open;
begin
  Visible := True;
  if (Host <> nil) and (Host.OwnerWindow is TControlWindow) then
    TControlWindow(Host.OwnerWindow).FocusControl(FEdit);
  FEdit.SelectAll;
end;

procedure TFindBar.Close;
begin
  Visible := False;
  FStatus.Text := '';
  if Assigned(FOnClosed) then
    FOnClosed(Self);
end;

procedure TFindBar.ShowResult(Found: Boolean);
begin
  if Found or (FEdit.Text = '') then
    FStatus.Text := ''
  else
    FStatus.Text := 'Not found';
end;

procedure TFindBar.Find(Forward, FromStart: Boolean);
begin
  if Assigned(FOnFind) then
    FOnFind(FEdit.Text, Forward, FMatchCase.Checked, FromStart);
end;

procedure TFindBar.EditChanged(Sender: TControl);
begin
  Find(True, True);
end;

procedure TFindBar.EditKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
begin
  if IsEnterKey(Code) then
  begin
    Find((Modifiers and ModifierShift) = 0, False);
    Handled := True;
  end
  else if Code = KeyEscape then
  begin
    Close;
    Handled := True;
  end;
end;

procedure TFindBar.PreviousClicked(Sender: TControl);
begin
  Find(False, False);
end;

procedure TFindBar.NextClicked(Sender: TControl);
begin
  Find(True, False);
end;

procedure TFindBar.CloseClicked(Sender: TControl);
begin
  Close;
end;

end.
