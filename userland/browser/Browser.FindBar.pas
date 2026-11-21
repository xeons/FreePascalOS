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
  The find bar along the bottom of the page (Ctrl+F; not a dialog): a
  close button, "Find:", what to find, Next, Previous, Highlight all,
  Match case and what happened ("Phrase not found", "Reached end of
  page, continued from top"). Typing finds as it goes (the box turns
  red when nothing matches); Enter finds the next match, Shift+Enter the
  one before, Escape closes the bar. The window does the finding
  (OnFind) and the highlighting (OnHighlight).
}
unit Browser.FindBar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.Panels,
  Controls.Labels,
  Controls.EditBox,
  Controls.Buttons,
  Controls.Toggles;

type
  TFindEvent = procedure(const Text: string; Forward, MatchCase, FromStart: Boolean) of object;
  THighlightEvent = procedure(const Text: string; MatchCase, Enabled: Boolean) of object;

  TFindBar = class(TPanel)
  private
    FClose: TButton;
    FCaption: TLabel;
    FEdit: TEditBox;
    FNext: TButton;
    FPrevious: TButton;
    FHighlight: TCheckBox;
    FMatchCase: TCheckBox;
    FStatus: TLabel;
    FNotFound: Boolean;
    FLastForward: Boolean;
    FOnFind: TFindEvent;
    FOnHighlight: THighlightEvent;
    FOnClosed: TControlEvent;
    procedure EditChanged(Sender: TControl);
    procedure EditKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure PreviousClicked(Sender: TControl);
    procedure NextClicked(Sender: TControl);
    procedure CloseClicked(Sender: TControl);
    procedure HighlightClicked(Sender: TControl);
    procedure MatchCaseClicked(Sender: TControl);
    procedure Find(Forward, FromStart: Boolean);
    procedure TellHighlight;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    { Shows the bar with the focus in its box, the text selected. }
    procedure Open;
    procedure Close;
    { What the last find did. }
    procedure ShowResult(Found, Wrapped: Boolean);
    procedure FindAgain(Forward: Boolean);
    function PreferredSize: TSize; override;
    property Edit: TEditBox read FEdit;
    property OnFind: TFindEvent read FOnFind write FOnFind;
    property OnHighlight: THighlightEvent read FOnHighlight write FOnHighlight;
    property OnClosed: TControlEvent read FOnClosed write FOnClosed;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Painting,
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
  FClose := TButton.Create(Self);
  FClose.Text := #195#151;
  FClose.Hint := 'Close the find bar (Esc)';
  FClose.SetBounds(0, 0, 22, 22);
  FClose.Flat := True;
  FClose.Align := AlignLeft;
  Spaced(FClose, 4, 4);
  FClose.OnClick := @CloseClicked;
  FCaption := TLabel.Create(Self);
  FCaption.Text := 'Fi&nd:';
  FCaption.AutoSize := True;
  FCaption.Align := AlignLeft;
  FCaption.Margins := MakeSpacing(4, 8, 4, 5);
  FEdit := TEditBox.Create(Self);
  FEdit.SetBounds(0, 0, 200, 22);
  FEdit.Align := AlignLeft;
  Spaced(FEdit, 2, 4);
  FEdit.OnChange := @EditChanged;
  FEdit.OnKeyDown := @EditKey;
  FNext := TButton.Create(Self);
  FNext.Text := 'Ne&xt';
  FNext.AutoSize := True;
  FNext.Flat := True;
  FNext.Align := AlignLeft;
  Spaced(FNext, 2, 2);
  FNext.OnClick := @NextClicked;
  FPrevious := TButton.Create(Self);
  FPrevious.Text := '&Previous';
  FPrevious.AutoSize := True;
  FPrevious.Flat := True;
  FPrevious.Align := AlignLeft;
  Spaced(FPrevious, 2, 6);
  FPrevious.OnClick := @PreviousClicked;
  FHighlight := TCheckBox.Create(Self);
  FHighlight.Text := 'Highlight &all';
  FHighlight.AutoSize := True;
  FHighlight.Align := AlignLeft;
  Spaced(FHighlight, 4, 6);
  FHighlight.OnClick := @HighlightClicked;
  FMatchCase := TCheckBox.Create(Self);
  FMatchCase.Text := 'Mat&ch case';
  FMatchCase.AutoSize := True;
  FMatchCase.Align := AlignLeft;
  Spaced(FMatchCase, 4, 8);
  FMatchCase.OnClick := @MatchCaseClicked;
  FStatus := TLabel.Create(Self);
  FStatus.Align := AlignClient;
  FStatus.Margins := MakeSpacing(4, 8, 4, 5);
  FLastForward := True;
  Visible := False;
end;

function TFindBar.PreferredSize: TSize;
begin
  Result.Width := 400;
  Result.Height := BarHeight;
end;

procedure TFindBar.Paint(var Canvas: TCanvas);
begin
  inherited Paint(Canvas);
  { Nothing found: the box is outlined in the error colour. }
  if FNotFound and (FEdit.Text <> '') then
    DrawThickOutline(Canvas, OffsetRectangle(FEdit.PixelBounds, -PixelBounds.Left, -PixelBounds.Top), Scaled(2),
      Theme.Error);
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
  if FHighlight.Checked and Assigned(FOnHighlight) then
    FOnHighlight('', False, False);
  if Assigned(FOnClosed) then
    FOnClosed(Self);
end;

procedure TFindBar.ShowResult(Found, Wrapped: Boolean);
begin
  FNotFound := not Found and (FEdit.Text <> '');
  if FEdit.Text = '' then
    FStatus.Text := ''
  else if not Found then
    FStatus.Text := 'Phrase not found'
  else if Wrapped and FLastForward then
    FStatus.Text := 'Reached end of page, continued from top'
  else if Wrapped then
    FStatus.Text := 'Reached top of page, continued from bottom'
  else
    FStatus.Text := '';
  Invalidate;
end;

procedure TFindBar.Find(Forward, FromStart: Boolean);
begin
  FLastForward := Forward;
  if Assigned(FOnFind) then
    FOnFind(FEdit.Text, Forward, FMatchCase.Checked, FromStart);
end;

procedure TFindBar.FindAgain(Forward: Boolean);
begin
  Find(Forward, False);
end;

procedure TFindBar.TellHighlight;
begin
  if Assigned(FOnHighlight) then
    FOnHighlight(FEdit.Text, FMatchCase.Checked, FHighlight.Checked);
end;

procedure TFindBar.EditChanged(Sender: TControl);
begin
  Find(True, True);
  if FHighlight.Checked then
    TellHighlight;
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

procedure TFindBar.HighlightClicked(Sender: TControl);
begin
  TellHighlight;
end;

procedure TFindBar.MatchCaseClicked(Sender: TControl);
begin
  Find(True, True);
  if FHighlight.Checked then
    TellHighlight;
end;

end.
