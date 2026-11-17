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
  Numeric up/down boxes: a number in an edit box, with spin buttons
  beside it to step it.

  The value stays between Minimum and Maximum, rounded to DecimalPlaces
  (shown as Controls.NumericValues does: with commas between thousands
  if ThousandsSeparator, in hexadecimal if Hexadecimal). The up and down
  arrows step it by Increment, Page Up and Page Down by ten increments,
  as do the wheel (an increment a notch) and the spin buttons (held,
  they repeat). Only characters of a number can be typed; what was typed
  is taken when the box loses the focus, when Enter is pressed, or
  before a step, and put back as it was if it is not a number. A new
  value is announced (OnValueChanged, and OnChange and NotifyChanged as
  every control does).

  The edit box (Editor) is what takes the focus: a label's mnemonic
  before the box reaches it.
}
unit Controls.NumericUpDown;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Messages,
  Controls.Base,
  Controls.EditBox,
  Controls.SpinButtons,
  Controls.NumericValues;

type
  TNumericUpDown = class;

  { The box's edit box: numbers only; it hands what was typed over when
    it loses the focus. }
  TNumericEdit = class(TEditBox)
  private
    FUpDown: TNumericUpDown;
  protected
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure FocusChanged; override;
  end;

  TNumericUpDown = class(TControl)
  private
    FEdit: TNumericEdit;
    FButtons: TSpinButtons;
    FValue: Double;
    FMinimum: Double;
    FMaximum: Double;
    FIncrement: Double;
    FDecimalPlaces: LongInt;
    FHexadecimal: Boolean;
    FThousandsSeparator: Boolean;
    FOnValueChanged: TControlEvent;
    function NumberFormat: TNumberFormat;
    procedure ShowValue;
    procedure SetValue(Value: Double);
    procedure SetMinimum(Value: Double);
    procedure SetMaximum(Value: Double);
    procedure SetDecimalPlaces(Value: LongInt);
    procedure SetHexadecimal(Value: Boolean);
    procedure SetThousandsSeparator(Value: Boolean);
    function GetIntegerValue: Int64;
    function GetEditor: TEditBox;
    procedure ButtonsStepped(Sender: TControl; Steps: LongInt);
  protected
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure Wheel(Steps: LongInt); override;
    procedure EnabledChanged; override;
    procedure ValueChanged; virtual;
  public
    constructor Create(AParent: TControl); override;
    { Its edit box's and buttons' notifications are its own business. }
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Takes what was typed (or puts the value back if it is not a
      number). }
    procedure Validate;
    { Steps increments up (down if negative), from what was typed. }
    procedure StepBy(Steps: LongInt);
    procedure SetRange(AMinimum, AMaximum: Double);
    property Value: Double read FValue write SetValue;
    { The value rounded to a whole number. }
    property IntegerValue: Int64 read GetIntegerValue;
    property Minimum: Double read FMinimum write SetMinimum;
    property Maximum: Double read FMaximum write SetMaximum;
    property Increment: Double read FIncrement write FIncrement;
    property DecimalPlaces: LongInt read FDecimalPlaces write SetDecimalPlaces;
    property Hexadecimal: Boolean read FHexadecimal write SetHexadecimal;
    property ThousandsSeparator: Boolean read FThousandsSeparator write SetThousandsSeparator;
    property Editor: TEditBox read GetEditor;
    property OnValueChanged: TControlEvent read FOnValueChanged write FOnValueChanged;
  end;

const
  { Page Up and Page Down step this many increments. }
  NumericPageSteps = 10;

implementation

uses
  Abi.SystemCalls,
  Windowing.Theme,
  Controls.Keys;

function TNumericEdit.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  { A character that cannot be in a number is not typed (but taken, so
    it goes nowhere else). }
  if (Character >= 32) and (Character <> 127) and ((Modifiers and ModifierControl) = 0) and
     not IsNumberCharacter(Character, FUpDown.NumberFormat) then
    Exit(True);
  Result := inherited KeyDown(Code, Character, Modifiers);
end;

procedure TNumericEdit.FocusChanged;
begin
  inherited FocusChanged;
  if not Focused then
    FUpDown.Validate;
end;

constructor TNumericUpDown.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FMinimum := 0;
  FMaximum := 100;
  FIncrement := 1;
  FButtons := TSpinButtons.Create(Self);
  FButtons.SetBounds(0, 0, Theme.ScrollBarWidth, 22);
  FButtons.Align := AlignRight;
  FButtons.OnStep := @ButtonsStepped;
  FEdit := TNumericEdit.Create(Self);
  FEdit.FUpDown := Self;
  FEdit.Align := AlignClient;
  ShowValue;
end;

function TNumericUpDown.NumberFormat: TNumberFormat;
begin
  Result := MakeNumberFormat(FDecimalPlaces, FHexadecimal, FThousandsSeparator);
end;

procedure TNumericUpDown.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and ((TControl(Message.Parameter1) = FEdit) or
     (TControl(Message.Parameter1) = FButtons)) then
    Exit;
  inherited ReceiveMessage(Message);
end;

procedure TNumericUpDown.ShowValue;
var
  Shown: string;
begin
  Shown := FormatNumber(FValue, NumberFormat);
  if FEdit.Text <> Shown then
    FEdit.Text := Shown;
end;

procedure TNumericUpDown.ValueChanged;
begin
  if Assigned(FOnValueChanged) then
    FOnValueChanged(Self);
  Changed;
end;

procedure TNumericUpDown.SetValue(Value: Double);
var
  Kept: Double;
begin
  Kept := ClampValue(RoundToFormat(Value, NumberFormat), FMinimum, FMaximum);
  if Kept = FValue then
  begin
    { The same value; what is shown may have been typed differently. }
    ShowValue;
    Exit;
  end;
  FValue := Kept;
  ShowValue;
  ValueChanged;
end;

procedure TNumericUpDown.SetRange(AMinimum, AMaximum: Double);
begin
  FMinimum := AMinimum;
  FMaximum := AMaximum;
  if FMaximum < FMinimum then
    FMaximum := FMinimum;
  SetValue(FValue);
end;

procedure TNumericUpDown.SetMinimum(Value: Double);
begin
  SetRange(Value, FMaximum);
end;

procedure TNumericUpDown.SetMaximum(Value: Double);
begin
  SetRange(FMinimum, Value);
end;

procedure TNumericUpDown.SetDecimalPlaces(Value: LongInt);
begin
  FDecimalPlaces := MakeNumberFormat(Value, False, False).DecimalPlaces;
  SetValue(FValue);
  ShowValue;
end;

procedure TNumericUpDown.SetHexadecimal(Value: Boolean);
begin
  FHexadecimal := Value;
  SetValue(FValue);
  ShowValue;
end;

procedure TNumericUpDown.SetThousandsSeparator(Value: Boolean);
begin
  FThousandsSeparator := Value;
  ShowValue;
end;

function TNumericUpDown.GetIntegerValue: Int64;
begin
  Result := Round(FValue);
end;

function TNumericUpDown.GetEditor: TEditBox;
begin
  Result := FEdit;
end;

procedure TNumericUpDown.Validate;
var
  Typed: Double;
begin
  if TryParseNumber(FEdit.Text, NumberFormat, Typed) then
    SetValue(Typed)
  else
    ShowValue;
end;

procedure TNumericUpDown.StepBy(Steps: LongInt);
var
  Typed: Double;
  From: Double;
begin
  From := FValue;
  if TryParseNumber(FEdit.Text, NumberFormat, Typed) then
    From := Typed;
  SetValue(StepValue(From, FIncrement, Steps, FMinimum, FMaximum, NumberFormat));
end;

procedure TNumericUpDown.ButtonsStepped(Sender: TControl; Steps: LongInt);
begin
  if not FEdit.Focused then
    FEdit.SetFocus;
  StepBy(Steps);
end;

function TNumericUpDown.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := True;
  case Code of
    KeyArrowUp: StepBy(1);
    KeyArrowDown: StepBy(-1);
    KeyPageUp: StepBy(NumericPageSteps);
    KeyPageDown: StepBy(-NumericPageSteps);
  else
    begin
      { Enter takes what was typed and still presses the default
        button. }
      if IsEnterKey(Code) then
        Validate;
      Result := False;
    end;
  end;
end;

procedure TNumericUpDown.Wheel(Steps: LongInt);
begin
  StepBy(Steps);
end;

procedure TNumericUpDown.EnabledChanged;
begin
  FEdit.Enabled := Enabled;
  FButtons.Enabled := Enabled;
end;

end.
