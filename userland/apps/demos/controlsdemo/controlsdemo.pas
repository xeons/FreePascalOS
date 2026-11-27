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
  controlsdemo - a window of controls (libcontrols), for trying and
  testing them

  controlsdemo

  A label and an edit box, a check box, two radio buttons in a group
  box, a scroll bar driving a progress bar, a colour swatch (a control
  made here, from the base every control uses), OK and Cancel (Enter
  and Escape), and a status bar; the swatch and the buttons have hints. The captions have mnemonics: Alt+N
  goes to the edit box, Alt+R toggles the check box, Alt+S and Alt+L
  choose a size, Alt+O presses OK. Prints what happens, a line each:

    edit TEXT              the edit box's text changed
    check 1 / check 0      the check box
    radio NAME             a radio button was chosen
    scroll N               the scroll bar moved to N
    swatch N               the swatch was clicked (its colour number)
    clicked NAME           a button
    scale P W H            the display's scale is now P percent: the
                           window's client area is W x H pixels
  and ends on OK, Cancel or closing the window.
}
program ControlsDemo;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Streams,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.Bevels,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.Messages,
  Windowing.Windows,
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.Panels,
  Controls.Buttons,
  Controls.Toggles,
  Controls.EditBox,
  Controls.ProgressBar,
  Controls.ScrollBar,
  Controls.StatusBar,
  Controls.Text;

const
  { The swatch tells the window it changed with a message of the
    program's own. }
  MessageSwatchChanged = MessageUser + 1;
  SwatchColors: array[0..3] of TColor = ($FFC03030, $FF30A040, $FF3050C0, $FFE0B020);

type
  { A control made here: a colour that changes when clicked. }
  TSwatch = class(TControl)
  private
    FColorIndex: LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    property ColorIndex: LongInt read FColorIndex;
  end;

  TDemoWindow = class(TControlWindow)
  private
    FEdit: TEditBox;
    FCheck: TCheckBox;
    FFirst: TRadioButton;
    FSecond: TRadioButton;
    FScroll: TScrollBar;
    FProgress: TProgressBar;
    FSwatch: TSwatch;
    FOk: TButton;
    FCancel: TButton;
    FStatus: TStatusBar;
    procedure ChildNotified(Sender: TControl; Child: TControl; Code: LongWord);
  protected
    procedure ScaleChanged; override;
  public
    constructor Create;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
  end;

procedure Say(const Text: string);
begin
  PrintStringLine(Text);
  FlushStream(StandardOutput);
end;

procedure TSwatch.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, SwatchColors[FColorIndex]);
  DrawBevel(Canvas, Box, SunkenBevel($FFFFFFFF, $FFE2DED6, $FF7E7A72, $FF35322D));
end;

procedure TSwatch.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  FColorIndex := (FColorIndex + 1) mod Length(SwatchColors);
  Invalidate;
  { Queued, delivered by the message loop. }
  PostMessage(Host.OwnerWindow, MessageSwatchChanged, FColorIndex);
end;

constructor TDemoWindow.Create;
var
  Caption: TLabel;
  Group: TGroupBox;
begin
  inherited Create('Controls', 120, 80, 360, 300);
  IconName := 'app-themes';
  Caption := TLabel.Create(Root);
  Caption.Text := '&Name:';
  Caption.SetBounds(12, 14, 60, 20);
  FEdit := TEditBox.Create(Root);
  FEdit.SetBounds(76, 12, 200, 22);
  FCheck := TCheckBox.Create(Root);
  FCheck.Text := '&Remember';
  FCheck.SetBounds(12, 44, 120, 20);
  Group := TGroupBox.Create(Root);
  Group.Text := 'Si&ze';
  Group.SetBounds(12, 72, 160, 70);
  FFirst := TRadioButton.Create(Group);
  FFirst.Text := '&Small';
  FFirst.SetBounds(10, 20, 120, 20);
  FFirst.Checked := True;
  FSecond := TRadioButton.Create(Group);
  FSecond.Text := '&Large';
  FSecond.SetBounds(10, 42, 120, 20);
  FScroll := TScrollBar.Create(Root);
  FScroll.Kind := ScrollHorizontal;
  FScroll.SetBounds(12, 154, 260, 16);
  FScroll.SetRange(0, 110, 10);
  FProgress := TProgressBar.Create(Root);
  FProgress.SetBounds(12, 178, 260, 18);
  FSwatch := TSwatch.Create(Root);
  FSwatch.SetBounds(290, 12, 56, 56);
  FSwatch.Hint := 'A control made by this program'#10'(click it for another colour)';
  FOk := TButton.Create(Root);
  FOk.Text := '&OK';
  FOk.IsDefault := True;
  FOk.SetBounds(190, 220, 75, 23);
  FOk.Hint := 'Close the window (Enter)';
  FCancel := TButton.Create(Root);
  FCancel.Text := 'Cancel';
  FCancel.SetBounds(272, 220, 75, 23);
  FCancel.Hint := 'Close the window (Escape)';
  FStatus := TStatusBar.Create(Root);
  FStatus.SetPanels([120, 0]);
  FStatus.PanelText[0] := 'Ready';
  DefaultControl := FOk;
  CancelControl := FCancel;
  { Every child's notification, in one place (Group's go to Group). }
  Root.OnNotify := @ChildNotified;
  Group.OnNotify := @ChildNotified;
  FEdit.SetFocus;
end;

procedure TDemoWindow.ChildNotified(Sender: TControl; Child: TControl; Code: LongWord);
begin
  if (Child = FEdit) and (Code = NotifyChanged) then
    Say('edit ' + FEdit.Text)
  else if (Child = FCheck) and (Code = NotifyChanged) then
    Say('check ' + IntToStr(Ord(FCheck.Checked)))
  else if (Child is TRadioButton) and (Code = NotifyChanged) and TRadioButton(Child).Checked then
    Say('radio ' + TextWithoutMnemonic(Child.Text))
  else if (Child = FScroll) and (Code = NotifyChanged) then
  begin
    FProgress.Position := FScroll.Position;
    FStatus.PanelText[1] := 'Position ' + IntToStr(FScroll.Position);
    Say('scroll ' + IntToStr(FScroll.Position));
  end
  else if (Child is TButton) and (Code = NotifyClicked) then
  begin
    Say('clicked ' + TextWithoutMnemonic(Child.Text));
    QuitMessageLoop(0);
  end;
end;

procedure TDemoWindow.ScaleChanged;
begin
  inherited ScaleChanged;
  Say('scale ' + IntToStr(DisplayScale) + ' ' + IntToStr(PixelWidth) + ' ' + IntToStr(PixelHeight));
end;

procedure TDemoWindow.ReceiveMessage(var Message: TPostedMessage);
begin
  if Message.Code = MessageSwatchChanged then
  begin
    FStatus.PanelText[0] := 'Colour ' + IntToStr(Message.Parameter1);
    Say('swatch ' + IntToStr(Message.Parameter1));
  end
  else
    inherited ReceiveMessage(Message);
end;

var
  Window: TDemoWindow;
begin
  Window := TDemoWindow.Create;
  Window.Show;
  RunMessageLoop;
end.
