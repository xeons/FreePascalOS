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
  The calculator's window: menus, the display, the mode's options (the
  angle unit; the base and word size), the memory buttons, the keypad
  and the history beside it.

  Nothing has a position of its own: the display, the options and the
  memory row are docked to the top and size themselves (AutoSize), the
  keypad is a table filling what is left (Calculator.Keypad), and the
  history is the second panel of a split container, collapsed while it
  is hidden. The keyboard types into the calculator wherever the focus
  is (Calculator.Actions has the characters; Enter is Equals, Escape
  Clear, Delete Clear Entry, Backspace takes back a digit, F9 changes
  the sign), except in the history list, whose arrows and Enter are its
  own. Ctrl+C copies the number, Ctrl+V pastes a number or an
  expression.

    View   Standard (Alt+1), Scientific (Alt+2), Programmer (Alt+3),
           History (Ctrl+H)
    Edit   Copy (Ctrl+C), Paste (Ctrl+V), Clear History
    Help   About Calculator

  The mode, angle unit, base, word size and whether the history shows
  are kept in the user's settings (Calculator.Settings) and taken again
  when they change elsewhere.
}
unit Calculator.MainWindow;

{$mode objfpc}
{$H+}

interface

uses
  Configuration.Changes,
  Controls.Base,
  Controls.Window,
  Controls.Menus,
  Controls.Panels,
  Controls.Labels,
  Controls.Buttons,
  Controls.Toggles,
  Controls.ListBox,
  Controls.FlowPanel,
  Controls.TablePanel,
  Controls.SplitContainer,
  Calculator.MathFunctions,
  Calculator.Engine,
  Calculator.Actions,
  Calculator.Display,
  Calculator.Keypad;

type
  TCalculatorWindow = class(TControlWindow)
  private
    FEngine: TCalculatorEngine;
    FMenuBar: TMenuBar;
    FModeItems: array[TCalculatorMode] of TMenuItem;
    FHistoryItem: TMenuItem;
    FSplit: TSplitContainer;
    FBody: TPanel;
    FDisplay: TCalculatorDisplay;
    FAngleRow: TFlowLayoutPanel;
    FAngleButtons: array[TAngleUnit] of TRadioButton;
    FBaseRow: TFlowLayoutPanel;
    FBaseButtons: array[0..3] of TRadioButton;
    FWordRow: TFlowLayoutPanel;
    FWordButtons: array[0..3] of TRadioButton;
    FMemoryRow: TTableLayoutPanel;
    FKeypad: TCalculatorKeypad;
    FHistoryList: TListBox;
    FUpdatingOptions: Boolean;
    procedure BuildMenus;
    procedure BuildBody;
    procedure BuildOptionRows;
    procedure BuildMemoryRow;
    procedure BuildHistory;
    function AddRadio(Row: TFlowLayoutPanel; const Caption: string; Tag: PtrInt): TRadioButton;
    function NewOptionRow: TFlowLayoutPanel;
    procedure BuildKeypad;
    procedure ShowMode;
    procedure ShowOptions;
    procedure Refresh;
    procedure RefreshHistory;
    procedure Perform(Action: TCalculatorAction);
    procedure KeypadAction(Action: TCalculatorAction);
    procedure MemoryClicked(Sender: TControl);
    procedure AngleClicked(Sender: TControl);
    procedure BaseClicked(Sender: TControl);
    procedure WordClicked(Sender: TControl);
    procedure HistoryActivated(Sender: TControl);
    procedure ClearHistoryClicked(Sender: TControl);
    procedure ModeChosen(Item: TMenuItem);
    procedure HistoryChosen(Item: TMenuItem);
    procedure CopyChosen(Item: TMenuItem);
    procedure PasteChosen(Item: TMenuItem);
    procedure ClearHistoryChosen(Item: TMenuItem);
    procedure AboutChosen(Item: TMenuItem);
    procedure ExitChosen(Item: TMenuItem);
    procedure StandardAccelerator(Sender: TControlWindow);
    procedure ScientificAccelerator(Sender: TControlWindow);
    procedure ProgrammerAccelerator(Sender: TControlWindow);
    procedure ApplySettings;
    procedure SettingsChanged(const Group: string; const Changes: TSettingChanges);
    procedure SetHistoryShown(Shown: Boolean);
    function TakesKeyItself(Code: LongWord): Boolean;
  protected
    procedure KeyDown(Code, Character, Modifiers: LongWord); override;
    procedure CloseRequested; override;
  public
    constructor Create;
    destructor Destroy; override;
    { As if Character were typed. }
    procedure TypeCharacter(Character: LongWord);
    property Engine: TCalculatorEngine read FEngine;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Windowing.Windows,
  Windowing.Clipboard,
  Windowing.SettingsChanges,
  Controls.Keys,
  Controls.LayoutRules,
  Controls.TableArrangement,
  Controls.SplitRules,
  Controls.MessageBoxes,
  Calculator.Settings,
  Calculator.Output;

const
  ProgramName = 'Calculator';
  { Logical units. }
  WindowWidth = 340;
  WindowHeight = 480;
  HistoryWidth = 200;
  BodyPadding = 6;
  RowGap = 4;
  MemoryRowHeight = 26;
  NoKey = 0;
  { Key codes Controls.Keys does not name. }
  KeyDigit1 = $02;
  KeyDigit2 = $03;
  KeyDigit3 = $04;
  KeyF9 = $43;
  KeyH = $23;
  KeyC = $2E;
  KeyV = $2F;
  OnOff: array[Boolean] of string = ('off', 'on');
  BaseValues: array[0..3] of LongInt = (16, 10, 8, 2);
  BaseCaptions: array[0..3] of string = ('He&x', 'De&c', '&Oct', '&Bin');
  WordValues: array[0..3] of LongInt = (64, 32, 16, 8);
  WordCaptions: array[0..3] of string = ('&QWord', '&DWord', '&Word', 'B&yte');
  AngleCaptions: array[TAngleUnit] of string = ('De&grees', '&Radians', 'Gr&adians');
  MemoryActions: array[0..4] of TCalculatorAction = (ActionMemoryClear, ActionMemoryRecall, ActionMemoryAdd,
    ActionMemorySubtract, ActionMemoryStore);

constructor TCalculatorWindow.Create;
var
  Settings: TCalculatorSettings;
begin
  inherited Create(ProgramName, 120, 80, WindowWidth, WindowHeight);
  IconName := 'app-calculator';
  FEngine := TCalculatorEngine.Create;
  Settings := RememberedSettings;
  FEngine.Mode := Settings.Mode;
  FEngine.Angles := Settings.Angles;
  FEngine.Base := Settings.Base;
  FEngine.WordBits := Settings.WordBits;
  BuildMenus;
  BuildBody;
  SetHistoryShown(Settings.HistoryShown);
  ShowMode;
  SubscribeToSettings(CalculatorSettingsGroup, @SettingsChanged);
  Say(Format('settings mode %s, angles %s, base %d, word %d, history %s', [ModeNames[Settings.Mode],
    AngleNames[Settings.Angles], Settings.Base, Settings.WordBits, OnOff[Settings.HistoryShown]]));
end;

destructor TCalculatorWindow.Destroy;
begin
  UnsubscribeFromSettings(@SettingsChanged);
  FEngine.Free;
  inherited Destroy;
end;

{ --- Building ---------------------------------------------------------------------------- }

procedure TCalculatorWindow.BuildMenus;
var
  Menu: TMenuItem;
  Item: TMenuItem;
begin
  FMenuBar := TMenuBar.Create(Root);
  Menu := FMenuBar.Menu.Add('&View');
  FModeItems[ModeStandard] := Menu.Add('&Standard', @ModeChosen, 'Alt+1');
  FModeItems[ModeScientific] := Menu.Add('S&cientific', @ModeChosen, 'Alt+2');
  FModeItems[ModeProgrammer] := Menu.Add('&Programmer', @ModeChosen, 'Alt+3');
  FModeItems[ModeStandard].Tag := Ord(ModeStandard);
  FModeItems[ModeScientific].Tag := Ord(ModeScientific);
  FModeItems[ModeProgrammer].Tag := Ord(ModeProgrammer);
  AddAccelerator(KeyDigit1, ModifierAlt, @StandardAccelerator);
  AddAccelerator(KeyDigit2, ModifierAlt, @ScientificAccelerator);
  AddAccelerator(KeyDigit3, ModifierAlt, @ProgrammerAccelerator);
  Menu.AddSeparator;
  FHistoryItem := Menu.Add('&History', @HistoryChosen, 'Ctrl+H');
  AddItemAccelerator(Self, FHistoryItem, KeyH, ModifierControl);
  Menu.AddSeparator;
  Menu.Add('E&xit', @ExitChosen);
  Menu := FMenuBar.Menu.Add('&Edit');
  Item := Menu.Add('&Copy', @CopyChosen, 'Ctrl+C');
  AddItemAccelerator(Self, Item, KeyC, ModifierControl);
  Item := Menu.Add('&Paste', @PasteChosen, 'Ctrl+V');
  AddItemAccelerator(Self, Item, KeyV, ModifierControl);
  Menu.AddSeparator;
  Menu.Add('Clear &History', @ClearHistoryChosen);
  Menu := FMenuBar.Menu.Add('&Help');
  Menu.Add('&About Calculator', @AboutChosen);
end;

procedure TCalculatorWindow.BuildBody;
begin
  FSplit := TSplitContainer.Create(Root);
  FSplit.Align := AlignClient;
  FSplit.FixedPanel := FixedPanel2;
  FSplit.Panel1MinSize := 220;
  FSplit.Panel2MinSize := 120;
  FSplit.SplitterDistance := WindowWidth;
  FBody := FSplit.Panel1;
  FBody.ContentPadding := MakeSpacing(BodyPadding, BodyPadding, BodyPadding, BodyPadding);
  FDisplay := TCalculatorDisplay.Create(FBody);
  FDisplay.Align := AlignTop;
  FDisplay.AutoSize := True;
  FDisplay.Margins := MakeSpacing(0, 0, 0, RowGap);
  BuildOptionRows;
  BuildMemoryRow;
  BuildHistory;
end;

function TCalculatorWindow.NewOptionRow: TFlowLayoutPanel;
begin
  Result := TFlowLayoutPanel.Create(FBody);
  Result.Align := AlignTop;
  Result.AutoSize := True;
  Result.WrapContents := True;
  Result.Margins := MakeSpacing(0, 0, 0, RowGap);
end;

function TCalculatorWindow.AddRadio(Row: TFlowLayoutPanel; const Caption: string; Tag: PtrInt): TRadioButton;
begin
  Result := TRadioButton.Create(Row);
  Result.Text := Caption;
  Result.Tag := Tag;
  Result.AutoSize := True;
  Result.Margins := MakeSpacing(0, 0, 10, 0);
end;

procedure TCalculatorWindow.BuildOptionRows;
var
  Angles: TAngleUnit;
  Index: LongInt;
begin
  FAngleRow := NewOptionRow;
  for Angles := Low(TAngleUnit) to High(TAngleUnit) do
  begin
    FAngleButtons[Angles] := AddRadio(FAngleRow, AngleCaptions[Angles], Ord(Angles));
    FAngleButtons[Angles].OnChange := @AngleClicked;
  end;
  FBaseRow := NewOptionRow;
  for Index := 0 to High(BaseValues) do
  begin
    FBaseButtons[Index] := AddRadio(FBaseRow, BaseCaptions[Index], BaseValues[Index]);
    FBaseButtons[Index].OnChange := @BaseClicked;
  end;
  FWordRow := NewOptionRow;
  for Index := 0 to High(WordValues) do
  begin
    FWordButtons[Index] := AddRadio(FWordRow, WordCaptions[Index], WordValues[Index]);
    FWordButtons[Index].OnChange := @WordClicked;
  end;
end;

procedure TCalculatorWindow.BuildMemoryRow;
var
  Index: LongInt;
  Button: TButton;
begin
  FMemoryRow := TTableLayoutPanel.Create(FBody);
  FMemoryRow.Align := AlignTop;
  FMemoryRow.AutoSize := True;
  FMemoryRow.AddRow(TrackAbsolute, MemoryRowHeight);
  for Index := 0 to High(MemoryActions) do
  begin
    FMemoryRow.AddColumn(TrackPercent, 1);
    Button := TButton.Create(FMemoryRow);
    Button.Text := ActionCaptions[MemoryActions[Index]];
    Button.Hint := ActionHints[MemoryActions[Index]];
    Button.ShowHint := True;
    Button.Tag := Ord(MemoryActions[Index]);
    Button.Align := AlignClient;
    Button.Margins := MakeSpacing(2, 0, 2, 0);
    Button.OnClick := @MemoryClicked;
    FMemoryRow.SetCell(Button, Index, 0);
  end;
  FMemoryRow.GrowStyle := GrowFixedSize;
  FMemoryRow.Margins := MakeSpacing(0, 0, 0, RowGap);
end;

procedure TCalculatorWindow.BuildHistory;
var
  Caption: TLabel;
  ClearButton: TButton;
  Panel: TPanel;
begin
  Panel := FSplit.Panel2;
  Panel.ContentPadding := MakeSpacing(BodyPadding, BodyPadding, BodyPadding, BodyPadding);
  Caption := TLabel.Create(Panel);
  Caption.Text := 'Histor&y';
  Caption.Align := AlignTop;
  Caption.AutoSize := True;
  ClearButton := TButton.Create(Panel);
  ClearButton.Text := 'C&lear History';
  ClearButton.Align := AlignBottom;
  ClearButton.AutoSize := True;
  ClearButton.Margins := MakeSpacing(0, RowGap, 0, 0);
  ClearButton.OnClick := @ClearHistoryClicked;
  FHistoryList := TListBox.Create(Panel);
  FHistoryList.Align := AlignClient;
  FHistoryList.OnActivate := @HistoryActivated;
end;

procedure TCalculatorWindow.BuildKeypad;
var
  Focused: Boolean;
begin
  Focused := (FocusedControl <> nil) and (FocusedControl.Parent = FKeypad);
  if Focused then
    FocusControl(nil);
  FreeAndNil(FKeypad);
  FKeypad := TCalculatorKeypad.CreateKeypad(FBody, FEngine.Mode);
  FKeypad.Align := AlignClient;
  FKeypad.OnAction := @KeypadAction;
  FKeypad.UpdateEnabled(FEngine.Base);
end;

{ --- Showing ------------------------------------------------------------------------------ }

procedure TCalculatorWindow.ShowOptions;
var
  Angles: TAngleUnit;
  Index: LongInt;
begin
  FUpdatingOptions := True;
  try
    for Angles := Low(TAngleUnit) to High(TAngleUnit) do
      FAngleButtons[Angles].Checked := FEngine.Angles = Angles;
    for Index := 0 to High(BaseValues) do
      FBaseButtons[Index].Checked := FEngine.Base = BaseValues[Index];
    for Index := 0 to High(WordValues) do
      FWordButtons[Index].Checked := FEngine.WordBits = WordValues[Index];
  finally
    FUpdatingOptions := False;
  end;
end;

procedure TCalculatorWindow.ShowMode;
var
  Mode: TCalculatorMode;
begin
  for Mode := Low(TCalculatorMode) to High(TCalculatorMode) do
    FModeItems[Mode].Checked := FEngine.Mode = Mode;
  FAngleRow.Visible := FEngine.Mode = ModeScientific;
  FBaseRow.Visible := FEngine.Mode = ModeProgrammer;
  FWordRow.Visible := FEngine.Mode = ModeProgrammer;
  ShowOptions;
  BuildKeypad;
  case FEngine.Mode of
    ModeScientific: Title := 'Calculator - Scientific';
    ModeProgrammer: Title := 'Calculator - Programmer';
  else
    Title := ProgramName;
  end;
  Refresh;
end;

procedure TCalculatorWindow.Refresh;
var
  Index: LongInt;
  Child: TControl;
begin
  FDisplay.Number := FEngine.DisplayText;
  FDisplay.Expression := FEngine.ExpressionText;
  FDisplay.MemoryShown := FEngine.HasMemory;
  for Index := 0 to FMemoryRow.ChildCount - 1 do
  begin
    Child := FMemoryRow.Children[Index];
    if TCalculatorAction(Child.Tag) in [ActionMemoryClear, ActionMemoryRecall] then
      Child.Enabled := FEngine.HasMemory;
  end;
end;

procedure TCalculatorWindow.RefreshHistory;
var
  Index: LongInt;
  Entry: THistoryEntry;
begin
  FHistoryList.Items.BeginUpdate;
  try
    FHistoryList.Items.Clear;
    { Newest first. }
    Index := FEngine.HistoryCount - 1;
    while Index >= 0 do
    begin
      Entry := FEngine.History[Index];
      FHistoryList.Items.Add(Entry.Expression + ' ' + Entry.Result);
      Dec(Index);
    end;
  finally
    FHistoryList.Items.EndUpdate;
  end;
end;

{ --- Acting ------------------------------------------------------------------------------- }

procedure TCalculatorWindow.Perform(Action: TCalculatorAction);
var
  HistoryBefore: LongInt;
begin
  if Action = ActionNone then
    Exit;
  HistoryBefore := FEngine.HistoryCount;
  PerformAction(FEngine, Action);
  Refresh;
  Say('display ' + FEngine.DisplayText);
  if FEngine.HistoryCount <> HistoryBefore then
  begin
    RefreshHistory;
    Say('result ' + FEngine.History[FEngine.HistoryCount - 1].Expression + ' ' + FEngine.DisplayText);
  end;
end;

procedure TCalculatorWindow.TypeCharacter(Character: LongWord);
begin
  Perform(ActionForCharacter(Character, FEngine.Mode, FEngine.Base));
end;

procedure TCalculatorWindow.KeypadAction(Action: TCalculatorAction);
begin
  Perform(Action);
end;

procedure TCalculatorWindow.MemoryClicked(Sender: TControl);
begin
  Perform(TCalculatorAction(Sender.Tag));
end;

procedure TCalculatorWindow.AngleClicked(Sender: TControl);
begin
  if FUpdatingOptions or not TRadioButton(Sender).Checked then
    Exit;
  FEngine.Angles := TAngleUnit(Sender.Tag);
  RememberAngles(FEngine.Angles);
  Say('angles ' + AngleNames[FEngine.Angles]);
end;

procedure TCalculatorWindow.BaseClicked(Sender: TControl);
begin
  if FUpdatingOptions or not TRadioButton(Sender).Checked then
    Exit;
  FEngine.Base := Sender.Tag;
  FKeypad.UpdateEnabled(FEngine.Base);
  RememberBase(FEngine.Base);
  Refresh;
  Say('base ' + IntToStr(FEngine.Base) + ' display ' + FEngine.DisplayText);
end;

procedure TCalculatorWindow.WordClicked(Sender: TControl);
begin
  if FUpdatingOptions or not TRadioButton(Sender).Checked then
    Exit;
  FEngine.WordBits := Sender.Tag;
  RememberWordBits(FEngine.WordBits);
  Refresh;
  Say('word ' + IntToStr(FEngine.WordBits) + ' display ' + FEngine.DisplayText);
end;

procedure TCalculatorWindow.HistoryActivated(Sender: TControl);
var
  Index: LongInt;
begin
  Index := FHistoryList.ItemIndex;
  if Index < 0 then
    Exit;
  { The list is newest first. }
  FEngine.RecallHistory(FEngine.HistoryCount - 1 - Index);
  Refresh;
  Say('display ' + FEngine.DisplayText);
end;

procedure TCalculatorWindow.ClearHistoryClicked(Sender: TControl);
begin
  FEngine.ClearHistory;
  RefreshHistory;
end;

procedure TCalculatorWindow.ClearHistoryChosen(Item: TMenuItem);
begin
  ClearHistoryClicked(nil);
end;

procedure TCalculatorWindow.ModeChosen(Item: TMenuItem);
begin
  if TCalculatorMode(Item.Tag) = FEngine.Mode then
    Exit;
  FEngine.Mode := TCalculatorMode(Item.Tag);
  RememberMode(FEngine.Mode);
  ShowMode;
  Say('mode ' + ModeNames[FEngine.Mode]);
end;

procedure TCalculatorWindow.StandardAccelerator(Sender: TControlWindow);
begin
  ModeChosen(FModeItems[ModeStandard]);
end;

procedure TCalculatorWindow.ScientificAccelerator(Sender: TControlWindow);
begin
  ModeChosen(FModeItems[ModeScientific]);
end;

procedure TCalculatorWindow.ProgrammerAccelerator(Sender: TControlWindow);
begin
  ModeChosen(FModeItems[ModeProgrammer]);
end;

procedure TCalculatorWindow.SetHistoryShown(Shown: Boolean);
begin
  FSplit.Panel2Collapsed := not Shown;
  FHistoryItem.Checked := Shown;
  if Shown then
    RefreshHistory;
end;

procedure TCalculatorWindow.HistoryChosen(Item: TMenuItem);
var
  Shown: Boolean;
begin
  Shown := FSplit.Panel2Collapsed;
  if Shown and (ClientWidth < WindowWidth + HistoryWidth) then
    SetClientSize(WindowWidth + HistoryWidth, ClientHeight);
  SetHistoryShown(Shown);
  if Shown then
    FSplit.SplitterDistance := ClientWidth - HistoryWidth;
  RememberHistoryShown(Shown);
  Say('history ' + OnOff[Shown]);
end;

procedure TCalculatorWindow.CopyChosen(Item: TMenuItem);
var
  Text: string;
begin
  Text := FEngine.CopyText;
  if Text = '' then
    Exit;
  WriteClipboardText(Text);
  Say('copied ' + Text);
end;

procedure TCalculatorWindow.PasteChosen(Item: TMenuItem);
var
  Text: string;
begin
  if not ReadClipboardText(Text) then
    Exit;
  if FEngine.Paste(Text) then
  begin
    Refresh;
    Say('pasted ' + FEngine.DisplayText);
  end
  else
    Say('paste refused');
end;

procedure TCalculatorWindow.AboutChosen(Item: TMenuItem);
begin
  ShowMessageBox('About Calculator', 'Calculator'#10'Standard, scientific and programmer arithmetic for ' +
    'FreePascalOS.', MessageOk, SignInformation, Self);
end;

procedure TCalculatorWindow.ExitChosen(Item: TMenuItem);
begin
  CloseRequested;
end;

procedure TCalculatorWindow.CloseRequested;
begin
  FlushClipboard;
  Say('exit');
  QuitMessageLoop(0);
end;

{ --- Settings ------------------------------------------------------------------------------- }

procedure TCalculatorWindow.ApplySettings;
var
  Settings: TCalculatorSettings;
begin
  Settings := RememberedSettings;
  if Settings.Mode <> FEngine.Mode then
  begin
    FEngine.Mode := Settings.Mode;
    ShowMode;
  end;
  FEngine.Angles := Settings.Angles;
  FEngine.Base := Settings.Base;
  FEngine.WordBits := Settings.WordBits;
  if Settings.HistoryShown = FSplit.Panel2Collapsed then
    SetHistoryShown(Settings.HistoryShown);
  ShowOptions;
  FKeypad.UpdateEnabled(FEngine.Base);
  Refresh;
end;

procedure TCalculatorWindow.SettingsChanged(const Group: string; const Changes: TSettingChanges);
begin
  ApplySettings;
end;

{ --- Keys --------------------------------------------------------------------------------------- }

{ The history list keeps its arrows and Enter. }
function TCalculatorWindow.TakesKeyItself(Code: LongWord): Boolean;
begin
  Result := (FocusedControl = FHistoryList) and ((Code = KeyArrowUp) or (Code = KeyArrowDown) or
    (Code = KeyHome) or (Code = KeyEnd) or (Code = KeyPageUp) or (Code = KeyPageDown) or IsEnterKey(Code));
end;

procedure TCalculatorWindow.KeyDown(Code, Character, Modifiers: LongWord);
var
  Action: TCalculatorAction;
begin
  if (Popup <> nil) or ((MenuBar <> nil) and MenuBar.InMenuMode) or
     ((Modifiers and (ModifierControl or ModifierAlt)) <> 0) or TakesKeyItself(Code) then
  begin
    inherited KeyDown(Code, Character, Modifiers);
    Exit;
  end;
  Action := ActionNone;
  if IsEnterKey(Code) then
    Action := ActionEquals
  else if Code = KeyEscape then
    Action := ActionClear
  else if Code = KeyDelete then
    Action := ActionClearEntry
  else if Code = KeyBackspace then
    Action := ActionBackspace
  else if Code = KeyF9 then
    Action := ActionNegate
  else if Character > 32 then
    Action := ActionForCharacter(Character, FEngine.Mode, FEngine.Base);
  if Action = ActionNone then
  begin
    inherited KeyDown(Code, Character, Modifiers);
    Exit;
  end;
  Perform(Action);
end;

end.
