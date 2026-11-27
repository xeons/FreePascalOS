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
  The calculator's buttons for each mode, in a table (TTableLayoutPanel)
  whose columns and rows share the room equally, every button filling
  its cell, so the keypad grows and shrinks with the window and nothing
  has a position of its own.

    Standard      %  CE  C  ⌫ / 1/x x² √x ÷ / 7 8 9 × / 4 5 6 − /
                  1 2 3 + / +/− 0 . =
    Scientific    trigonometry, powers, roots, logarithms and
                  parentheses above the digits; 0 and = span two cells
    Programmer    the bit operators, A-F beside the digits

  A button's Tag is its action (Calculator.Actions); the ones the mode
  or the base leaves no meaning disabled.
}
unit Calculator.Keypad;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Buttons,
  Controls.TablePanel,
  Calculator.Engine,
  Calculator.Actions;

type
  TActionEvent = procedure(Action: TCalculatorAction) of object;

  TCalculatorKeypad = class(TTableLayoutPanel)
  private
    FMode: TCalculatorMode;
    FOnAction: TActionEvent;
    procedure ButtonClicked(Sender: TControl);
    procedure AddButton(Action: TCalculatorAction; Column, Row: LongInt; ColumnSpan: LongInt = 1;
      RowSpan: LongInt = 1);
    procedure AddButtonRow(Row: LongInt; const Actions: array of TCalculatorAction);
    procedure BuildStandard;
    procedure BuildScientific;
    procedure BuildProgrammer;
    procedure SetUpTracks(Columns, Rows: LongInt);
  public
    constructor CreateKeypad(AParent: TControl; Mode: TCalculatorMode);
    { Enables the buttons that mean something in base Base. }
    procedure UpdateEnabled(Base: LongInt);
    { The button of Action, or nil. }
    function ButtonOf(Action: TCalculatorAction): TButton;
    property Mode: TCalculatorMode read FMode;
    property OnAction: TActionEvent read FOnAction write FOnAction;
  end;

implementation

uses
  Controls.LayoutRules,
  Controls.TableArrangement;

const
  { Logical units between buttons. }
  ButtonGap = 2;
  ShareOfEach = 1;

constructor TCalculatorKeypad.CreateKeypad(AParent: TControl; Mode: TCalculatorMode);
begin
  inherited Create(AParent);
  FMode := Mode;
  case Mode of
    ModeScientific: BuildScientific;
    ModeProgrammer: BuildProgrammer;
  else
    BuildStandard;
  end;
end;

procedure TCalculatorKeypad.SetUpTracks(Columns, Rows: LongInt);
var
  Index: LongInt;
begin
  for Index := 1 to Columns do
    AddColumn(TrackPercent, ShareOfEach);
  for Index := 1 to Rows do
    AddRow(TrackPercent, ShareOfEach);
  GrowStyle := GrowFixedSize;
end;

procedure TCalculatorKeypad.ButtonClicked(Sender: TControl);
begin
  if Assigned(FOnAction) then
    FOnAction(TCalculatorAction(Sender.Tag));
end;

procedure TCalculatorKeypad.AddButton(Action: TCalculatorAction; Column, Row: LongInt; ColumnSpan: LongInt;
  RowSpan: LongInt);
var
  Button: TButton;
begin
  if Action = ActionNone then
    Exit;
  Button := TButton.Create(Self);
  { Captions are symbols: an ampersand is not a mnemonic here. }
  Button.Text := ActionCaptions[Action];
  Button.Tag := Ord(Action);
  Button.Hint := ActionHints[Action];
  Button.ShowHint := Button.Hint <> '';
  Button.Align := AlignClient;
  Button.Margins := MakeSpacing(ButtonGap, ButtonGap, ButtonGap, ButtonGap);
  { The keyboard types into the calculator; Tab still reaches the buttons. }
  Button.OnClick := @ButtonClicked;
  SetCell(Button, Column, Row);
  if (ColumnSpan > 1) or (RowSpan > 1) then
    SetSpan(Button, ColumnSpan, RowSpan);
end;

procedure TCalculatorKeypad.AddButtonRow(Row: LongInt; const Actions: array of TCalculatorAction);
var
  Column: LongInt;
begin
  for Column := 0 to High(Actions) do
    AddButton(Actions[Column], Column, Row);
end;

procedure TCalculatorKeypad.BuildStandard;
begin
  SetUpTracks(4, 6);
  AddButtonRow(0, [ActionPercent, ActionClearEntry, ActionClear, ActionBackspace]);
  AddButtonRow(1, [ActionReciprocal, ActionSquare, ActionSquareRoot, ActionDivide]);
  AddButtonRow(2, [ActionDigit7, ActionDigit8, ActionDigit9, ActionMultiply]);
  AddButtonRow(3, [ActionDigit4, ActionDigit5, ActionDigit6, ActionSubtract]);
  AddButtonRow(4, [ActionDigit1, ActionDigit2, ActionDigit3, ActionAdd]);
  AddButtonRow(5, [ActionNegate, ActionDigit0, ActionPoint, ActionEquals]);
end;

procedure TCalculatorKeypad.BuildScientific;
begin
  SetUpTracks(5, 10);
  AddButtonRow(0, [ActionSine, ActionCosine, ActionTangent, ActionPi, ActionEuler]);
  AddButtonRow(1, [ActionArcSine, ActionArcCosine, ActionArcTangent, ActionPower, ActionRoot]);
  AddButtonRow(2, [ActionSinh, ActionCosh, ActionTanh, ActionSquare, ActionCube]);
  AddButtonRow(3, [ActionNaturalLog, ActionCommonLog, ActionExponential, ActionTenPower, ActionFactorial]);
  AddButtonRow(4, [ActionSquareRoot, ActionCubeRoot, ActionReciprocal, ActionAbsolute, ActionModulo]);
  AddButtonRow(5, [ActionOpen, ActionClose, ActionClearEntry, ActionClear, ActionBackspace]);
  AddButtonRow(6, [ActionDigit7, ActionDigit8, ActionDigit9, ActionDivide, ActionPercent]);
  AddButtonRow(7, [ActionDigit4, ActionDigit5, ActionDigit6, ActionMultiply, ActionNegate]);
  AddButtonRow(8, [ActionDigit1, ActionDigit2, ActionDigit3, ActionSubtract]);
  AddButton(ActionEquals, 4, 8, 1, 2);
  AddButton(ActionDigit0, 0, 9, 2, 1);
  AddButton(ActionPoint, 2, 9);
  AddButton(ActionAdd, 3, 9);
end;

procedure TCalculatorKeypad.BuildProgrammer;
begin
  SetUpTracks(6, 6);
  AddButtonRow(0, [ActionShiftLeft, ActionShiftRight, ActionOr, ActionXor, ActionNot, ActionAnd]);
  AddButtonRow(1, [ActionSquare, ActionModulo, ActionClearEntry, ActionClear, ActionBackspace, ActionDivide]);
  AddButtonRow(2, [ActionDigitA, ActionDigitB, ActionDigit7, ActionDigit8, ActionDigit9, ActionMultiply]);
  AddButtonRow(3, [ActionDigitC, ActionDigitD, ActionDigit4, ActionDigit5, ActionDigit6, ActionSubtract]);
  AddButtonRow(4, [ActionDigitE, ActionDigitF, ActionDigit1, ActionDigit2, ActionDigit3, ActionAdd]);
  AddButtonRow(5, [ActionOpen, ActionClose, ActionNegate, ActionDigit0, ActionFactorial, ActionEquals]);
end;

procedure TCalculatorKeypad.UpdateEnabled(Base: LongInt);
var
  Index: LongInt;
  Child: TControl;
begin
  for Index := 0 to ChildCount - 1 do
  begin
    Child := Children[Index];
    if Child is TButton then
      Child.Enabled := ActionAvailable(TCalculatorAction(Child.Tag), FMode, Base);
  end;
end;

function TCalculatorKeypad.ButtonOf(Action: TCalculatorAction): TButton;
var
  Index: LongInt;
begin
  for Index := 0 to ChildCount - 1 do
    if (Children[Index] is TButton) and (Children[Index].Tag = Ord(Action)) then
      Exit(TButton(Children[Index]));
  Result := nil;
end;

end.
