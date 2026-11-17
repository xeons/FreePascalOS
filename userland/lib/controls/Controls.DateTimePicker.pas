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
  Date and time pickers: a date, a time or both in a field like an edit
  box's, edited one part at a time.

  The parts shown come from a pattern (Controls.DateFormats): the short
  or long one of the kind (DateTimeKindDate, DateTimeKindTime,
  DateTimeKindDateTime), or the program's own (DateTimeFormatCustom,
  Pattern). One part is picked: Left and Right (and a separator typed)
  move to the part either side, Home and End to the first and last; Up
  and Down step it, wrapping around (as do the wheel and, beside a time,
  the spin buttons); digits type it, going on to the next part when it
  is full; A and P choose AM or PM. A click picks the part under it. A
  picker with a date has a drop button: a click on it, Alt+Down or F4
  drop a month calendar (Controls.Calendar) below it, in a pop-up; a
  date clicked there (or Enter) is taken, Escape or a click elsewhere
  closes it.

  With ShowCheckBox a check box comes first (a click or Space toggles
  it): unchecked, the value is shown grey and stands for none
  (Checked). The date is kept within MinDate and MaxDate. Times are
  local times of a time zone (TimeZone; the program's, Sys.LocalTime,
  unless set): SetToNow and UnixTime convert from and to the moment. A
  new value is announced (OnChange, NotifyChanged).
}
unit Controls.DateTimePicker;

{$mode objfpc}
{$H+}

interface

uses
  Runtime.Time,
  Drawing.Rectangles,
  Drawing.Canvas,
  Sys.TimeZones,
  Windowing.Messages,
  Controls.Base,
  Controls.Popups,
  Controls.SpinButtons,
  Controls.Calendar,
  Controls.CalendarDates,
  Controls.DateFormats;

type
  TDateTimeKind = (DateTimeKindDate, DateTimeKindTime, DateTimeKindDateTime);
  TDateTimeFormat = (DateTimeFormatShort, DateTimeFormatLong, DateTimeFormatCustom);

  TDateTimePicker = class;

  { The dropped calendar: Escape closes it. }
  TPickerCalendar = class(TCalendar)
  private
    FPicker: TDateTimePicker;
  protected
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  end;

  TDateTimePicker = class(TControl)
  private
    FKind: TDateTimeKind;
    FFormat: TDateTimeFormat;
    FCustomPattern: string;
    FFields: TDateTimeFields;
    FValue: TDateTimeParts;
    { The part picked (an editable one), and the digits typed into it. }
    FFieldIndex: LongInt;
    FTyping: TFieldTyping;
    FShowCheckBox: Boolean;
    FChecked: Boolean;
    FMinDate: TCalendarDate;
    FMaxDate: TCalendarDate;
    FTimeZone: PTimeZone;
    FSpin: TSpinButtons;
    FPopup: TPopupWindow;
    FCalendar: TPickerCalendar;
    FOnDropDown: TControlEvent;
    FOnCloseUp: TControlEvent;
    procedure SetKind(Value: TDateTimeKind);
    procedure SetFormat(Value: TDateTimeFormat);
    procedure SetCustomPattern(const Value: string);
    procedure SetShowCheckBox(Value: Boolean);
    procedure SetChecked(Value: Boolean);
    procedure SetMinDate(const Value: TCalendarDate);
    procedure SetMaxDate(const Value: TCalendarDate);
    procedure SetValue(const Value: TDateTimeParts);
    function GetDate: TCalendarDate;
    procedure SetDate(const Value: TCalendarDate);
    function Zone: PTimeZone;
    procedure UpdateFields;
    function HasDateFields: Boolean;
    function Editable: Boolean;
    function CheckBoxBounds: TRectangle;
    function ButtonBounds: TRectangle;
    function FieldsLeft: LongInt;
    function FieldLeft(Index: LongInt): LongInt;
    function FieldWidth(Index: LongInt): LongInt;
    function FieldAt(X: LongInt): LongInt;
    procedure PickField(Index: LongInt);
    procedure MoveToField(Direction: LongInt);
    procedure FinishTyping;
    procedure ChangeValue(const Parts: TDateTimeParts);
    procedure StepPicked(Steps: LongInt);
    procedure SpinStepped(Sender: TControl; Steps: LongInt);
    procedure TypeDigit(Digit: LongInt);
    function TypeCharacter(Character: LongWord): Boolean;
    procedure CalendarPicked(Sender: TControl);
    procedure CalendarDismissed(Sender: TControl);
    procedure PaintFields(var Canvas: TCanvas; const Box: TRectangle);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure FocusChanged; override;
    procedure EnabledChanged; override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { Its spin buttons' notifications are its own business. }
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    procedure DropDown;
    procedure CloseUp;
    function DroppedDown: Boolean;
    { The time now in the zone. }
    procedure SetToNow;
    { The moment the value stands for in the zone, and back. }
    function UnixTime: TUnixTime;
    procedure SetUnixTime(Time: TUnixTime);
    { The pattern in use. }
    function Pattern: string;
    { The value as shown ("2026-11-16"). }
    function ValueText: string;
    property Kind: TDateTimeKind read FKind write SetKind;
    property Format: TDateTimeFormat read FFormat write SetFormat;
    { The pattern of DateTimeFormatCustom. }
    property CustomPattern: string read FCustomPattern write SetCustomPattern;
    property Value: TDateTimeParts read FValue write SetValue;
    property Date: TCalendarDate read GetDate write SetDate;
    property ShowCheckBox: Boolean read FShowCheckBox write SetShowCheckBox;
    { Without the check box: always. }
    property Checked: Boolean read FChecked write SetChecked;
    property MinDate: TCalendarDate read FMinDate write SetMinDate;
    property MaxDate: TCalendarDate read FMaxDate write SetMaxDate;
    { nil: the program's zone. }
    property TimeZone: PTimeZone read FTimeZone write FTimeZone;
    { The calendar while it is dropped (nil otherwise). }
    property DroppedCalendar: TPickerCalendar read FCalendar;
    { The calendar has dropped (it is shown), or closed. }
    property OnDropDown: TControlEvent read FOnDropDown write FOnDropDown;
    property OnCloseUp: TControlEvent read FOnCloseUp write FOnCloseUp;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Bevels,
  Sys.Time,
  Sys.LocalTime,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.Window,
  Controls.Buttons,
  Controls.CheckMarks;

function TPickerCalendar.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  if (Code = KeyEscape) or ((Code = KeyArrowUp) and ((Modifiers and ModifierAlt) <> 0)) or (Code = KeyF4) then
  begin
    FPicker.CloseUp;
    Exit(True);
  end;
  Result := inherited KeyDown(Code, Character, Modifiers);
end;

{ --- Value ---------------------------------------------------------------------- }

function PartsAtMoment(TimeZone: PTimeZone; Time: TUnixTime): TDateTimeParts;
var
  Local: TLocalTime;
begin
  DecodeTimeInZone(TimeZone, Time, Local);
  Result := MakeDateTimeParts(Local.DateTime.Year, Local.DateTime.Month, Local.DateTime.Day, Local.DateTime.Hour,
    Local.DateTime.Minute, Local.DateTime.Second);
end;

function NowInZone(TimeZone: PTimeZone): TDateTimeParts;
begin
  Result := PartsAtMoment(TimeZone, CurrentTime);
end;

constructor TDateTimePicker.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FChecked := True;
  FMinDate := NoCalendarDate;
  FMaxDate := NoCalendarDate;
  FFieldIndex := -1;
  StartFieldTyping(FTyping);
  { The time now, not announced: nobody can be listening yet. }
  FValue := NowInZone(CurrentTimeZone);
  UpdateFields;
end;

destructor TDateTimePicker.Destroy;
begin
  CloseUp;
  inherited Destroy;
end;

function TDateTimePicker.Zone: PTimeZone;
begin
  Result := FTimeZone;
  if Result = nil then
    Result := CurrentTimeZone;
end;

procedure TDateTimePicker.SetToNow;
begin
  SetUnixTime(CurrentTime);
end;

procedure TDateTimePicker.SetUnixTime(Time: TUnixTime);
begin
  SetValue(PartsAtMoment(Zone, Time));
end;

function TDateTimePicker.UnixTime: TUnixTime;
begin
  Result := ZoneLocalTimeToUnixTime(Zone, FValue.Date.Year, FValue.Date.Month, FValue.Date.Day, FValue.Hour,
    FValue.Minute, FValue.Second);
end;

function TDateTimePicker.Pattern: string;
var
  DatePattern: string;
  TimePattern: string;
begin
  if (FFormat = DateTimeFormatCustom) and (FCustomPattern <> '') then
    Exit(FCustomPattern);
  if FFormat = DateTimeFormatLong then
  begin
    DatePattern := LongDatePattern;
    TimePattern := LongTimePattern;
  end
  else
  begin
    DatePattern := ShortDatePattern;
    TimePattern := ShortTimePattern;
  end;
  case FKind of
    DateTimeKindDate: Result := DatePattern;
    DateTimeKindTime: Result := TimePattern;
  else
    Result := DatePattern + ' ' + TimePattern;
  end;
end;

function TDateTimePicker.ValueText: string;
begin
  Result := FormatDateTimeParts(FFields, FValue);
end;

function TDateTimePicker.HasDateFields: Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to High(FFields) do
    if FieldIsDate(FFields[Index].Kind) then
      Exit(True);
  Result := False;
end;

{ The pattern split again: the first editable part picked, spin buttons
  for a picker without a date, a drop button for one with. }
procedure TDateTimePicker.UpdateFields;
begin
  CloseUp;
  FFields := ParseDateTimePattern(Pattern);
  FFieldIndex := -1;
  MoveToField(1);
  if HasDateFields then
  begin
    FSpin.Free;
    FSpin := nil;
  end
  else if FSpin = nil then
  begin
    FSpin := TSpinButtons.Create(Self);
    FSpin.OnStep := @SpinStepped;
    FSpin.Enabled := Enabled;
    UpdatePixelBounds;
  end;
  Invalidate;
end;

procedure TDateTimePicker.SetKind(Value: TDateTimeKind);
begin
  FKind := Value;
  UpdateFields;
end;

procedure TDateTimePicker.SetFormat(Value: TDateTimeFormat);
begin
  FFormat := Value;
  UpdateFields;
end;

procedure TDateTimePicker.SetCustomPattern(const Value: string);
begin
  FCustomPattern := Value;
  if FFormat = DateTimeFormatCustom then
    UpdateFields;
end;

procedure TDateTimePicker.SetShowCheckBox(Value: Boolean);
begin
  FShowCheckBox := Value;
  if not Value then
    FChecked := True;
  Invalidate;
end;

procedure TDateTimePicker.SetChecked(Value: Boolean);
begin
  if not FShowCheckBox then
    Value := True;
  if FChecked = Value then
    Exit;
  FChecked := Value;
  Invalidate;
  Changed;
end;

function TDateTimePicker.Editable: Boolean;
begin
  Result := Enabled and FChecked;
end;

procedure TDateTimePicker.SetMinDate(const Value: TCalendarDate);
begin
  FMinDate := Value;
  ChangeValue(FValue);
end;

procedure TDateTimePicker.SetMaxDate(const Value: TCalendarDate);
begin
  FMaxDate := Value;
  ChangeValue(FValue);
end;

{ Parts as the value, the date kept within the limits; announced if it
  is new. }
procedure TDateTimePicker.ChangeValue(const Parts: TDateTimeParts);
var
  Kept: TDateTimeParts;
begin
  Kept := Parts;
  Kept.Date := ClampDate(Parts.Date, FMinDate, FMaxDate);
  if CompareDateTimeParts(Kept, FValue) = 0 then
    Exit;
  FValue := Kept;
  if FCalendar <> nil then
    FCalendar.Date := FValue.Date;
  Invalidate;
  Changed;
end;

procedure TDateTimePicker.SetValue(const Value: TDateTimeParts);
begin
  if not IsValidDate(Value.Date) then
    Exit;
  StartFieldTyping(FTyping);
  ChangeValue(Value);
end;

function TDateTimePicker.GetDate: TCalendarDate;
begin
  Result := FValue.Date;
end;

procedure TDateTimePicker.SetDate(const Value: TCalendarDate);
var
  Parts: TDateTimeParts;
begin
  Parts := FValue;
  Parts.Date := Value;
  SetValue(Parts);
end;

{ --- Where things are ----------------------------------------------------------- }

function TDateTimePicker.CheckBoxBounds: TRectangle;
var
  Size: LongInt;
begin
  Size := CheckMarkSize;
  Result := MakeRectangle(Scaled(4), (RectangleHeight(PixelBounds) - Size) div 2, Size, Size);
end;

{ The drop button (or where the spin buttons go), inside the bevel. }
function TDateTimePicker.ButtonBounds: TRectangle;
var
  Width: LongInt;
begin
  Width := Scaled(Theme.ScrollBarWidth);
  Result := MakeRectangle(RectangleWidth(PixelBounds) - 2 - Width, 2, Width, RectangleHeight(PixelBounds) - 4);
end;

function TDateTimePicker.FieldsLeft: LongInt;
begin
  Result := Scaled(4);
  if FShowCheckBox then
    Result := CheckBoxBounds.Right + Scaled(5);
end;

function TDateTimePicker.FieldLeft(Index: LongInt): LongInt;
var
  Before: string;
  Position: LongInt;
begin
  Before := '';
  for Position := 0 to Index - 1 do
    Before := Before + FieldText(FFields[Position], FValue);
  Result := FieldsLeft + TextWidth(ControlFace, Before);
end;

function TDateTimePicker.FieldWidth(Index: LongInt): LongInt;
begin
  Result := TextWidth(ControlFace, FieldText(FFields[Index], FValue));
end;

{ The editable part at X (pixels), or the nearest after it; -1 if none. }
function TDateTimePicker.FieldAt(X: LongInt): LongInt;
var
  Index: LongInt;
  Last: LongInt;
begin
  Last := -1;
  for Index := 0 to High(FFields) do
  begin
    if not FieldIsEditable(FFields[Index].Kind) then
      Continue;
    Last := Index;
    if X < FieldLeft(Index) + FieldWidth(Index) then
      Exit(Index);
  end;
  Result := Last;
end;

procedure TDateTimePicker.Layout;
var
  Button: TRectangle;
begin
  if FSpin <> nil then
  begin
    Button := ButtonBounds;
    FSpin.AssignBounds(Unscaled(Button.Left), Unscaled(Button.Top), Unscaled(RectangleWidth(Button)),
      Unscaled(RectangleHeight(Button)));
  end;
  inherited Layout;
end;

procedure TDateTimePicker.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and (FSpin <> nil) and (TControl(Message.Parameter1) = FSpin) then
    Exit;
  inherited ReceiveMessage(Message);
end;

{ --- Editing -------------------------------------------------------------------- }

procedure TDateTimePicker.FinishTyping;
var
  Parts: TDateTimeParts;
begin
  if (FFieldIndex >= 0) and (FTyping.Digits > 0) then
  begin
    Parts := FinishFieldTyping(FTyping, FValue, FFields[FFieldIndex].Kind);
    StartFieldTyping(FTyping);
    ChangeValue(Parts);
  end;
  StartFieldTyping(FTyping);
end;

procedure TDateTimePicker.PickField(Index: LongInt);
begin
  if (Index < 0) or (Index > High(FFields)) or not FieldIsEditable(FFields[Index].Kind) then
    Exit;
  if Index <> FFieldIndex then
    FinishTyping;
  FFieldIndex := Index;
  Invalidate;
end;

{ The next editable part in Direction (+1 right, -1 left); none past
  the ends. From none picked, +1 finds the first. }
procedure TDateTimePicker.MoveToField(Direction: LongInt);
var
  Index: LongInt;
begin
  Index := FFieldIndex + Direction;
  if FFieldIndex < 0 then
    Index := 0;
  while (Index >= 0) and (Index <= High(FFields)) do
  begin
    if FieldIsEditable(FFields[Index].Kind) then
    begin
      PickField(Index);
      Exit;
    end;
    Index := Index + Direction;
  end;
end;

procedure TDateTimePicker.StepPicked(Steps: LongInt);
begin
  if not Editable or (FFieldIndex < 0) then
    Exit;
  FinishTyping;
  ChangeValue(StepField(FValue, FFields[FFieldIndex].Kind, Steps));
end;

procedure TDateTimePicker.SpinStepped(Sender: TControl; Steps: LongInt);
begin
  SetFocus;
  StepPicked(Steps);
end;

procedure TDateTimePicker.TypeDigit(Digit: LongInt);
var
  Complete: Boolean;
  Parts: TDateTimeParts;
begin
  if not Editable or (FFieldIndex < 0) then
    Exit;
  Parts := TypeFieldDigit(FTyping, FValue, FFields[FFieldIndex].Kind, Digit, Complete);
  ChangeValue(Parts);
  if Complete then
  begin
    StartFieldTyping(FTyping);
    MoveToField(1);
  end;
end;

{ A character typed: a digit, A or P for the half of the day, or the
  separator after the part (going on to the next). }
function TDateTimePicker.TypeCharacter(Character: LongWord): Boolean;
var
  Index: LongInt;
begin
  Result := True;
  if (Character >= Ord('0')) and (Character <= Ord('9')) then
  begin
    TypeDigit(Character - Ord('0'));
    Exit;
  end;
  if (FFieldIndex >= 0) and (FFields[FFieldIndex].Kind = FieldDayPeriod) and Editable then
  begin
    if (Character = Ord('a')) or (Character = Ord('A')) then
    begin
      ChangeValue(SetFieldNumber(FValue, FieldDayPeriod, 0));
      Exit;
    end;
    if (Character = Ord('p')) or (Character = Ord('P')) then
    begin
      ChangeValue(SetFieldNumber(FValue, FieldDayPeriod, 1));
      Exit;
    end;
  end;
  Index := FFieldIndex + 1;
  if (FFieldIndex >= 0) and (Index <= High(FFields)) and (FFields[Index].Kind = FieldLiteral) and
     (Pos(Char(Character), FFields[Index].Literal) > 0) and (Character < 128) then
  begin
    MoveToField(1);
    Exit;
  end;
  Result := False;
end;

function TDateTimePicker.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := True;
  if HasDateFields and (((Code = KeyArrowDown) and ((Modifiers and ModifierAlt) <> 0)) or (Code = KeyF4)) then
  begin
    if DroppedDown then
      CloseUp
    else
      DropDown;
    Exit;
  end;
  case Code of
    KeyArrowLeft:
      begin
        FinishTyping;
        MoveToField(-1);
      end;
    KeyArrowRight:
      begin
        FinishTyping;
        MoveToField(1);
      end;
    KeyHome:
      begin
        FinishTyping;
        FFieldIndex := -1;
        MoveToField(1);
      end;
    KeyEnd:
      begin
        FinishTyping;
        FFieldIndex := Length(FFields);
        MoveToField(-1);
      end;
    KeyArrowUp: StepPicked(1);
    KeyArrowDown: StepPicked(-1);
    KeySpace:
      if FShowCheckBox then
        SetChecked(not FChecked)
      else
        Result := False;
  else
    begin
      if IsEnterKey(Code) then
        FinishTyping;
      if (Character >= 32) and ((Modifiers and (ModifierControl or ModifierAlt)) = 0) then
        Result := TypeCharacter(Character)
      else
        Result := False;
    end;
  end;
end;

procedure TDateTimePicker.Wheel(Steps: LongInt);
begin
  StepPicked(Steps);
end;

procedure TDateTimePicker.FocusChanged;
begin
  if not Focused then
    FinishTyping;
  inherited FocusChanged;
end;

procedure TDateTimePicker.EnabledChanged;
begin
  if FSpin <> nil then
    FSpin.Enabled := Enabled;
  if not Enabled then
    CloseUp;
end;

procedure TDateTimePicker.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Box: TRectangle;
begin
  if Button <> ButtonLeft then
    Exit;
  if FShowCheckBox then
  begin
    Box := InflateRectangle(CheckBoxBounds, Scaled(2));
    if RectangleContainsPoint(Box, X, Y) then
    begin
      SetChecked(not FChecked);
      Exit;
    end;
  end;
  if HasDateFields and RectangleContainsPoint(ButtonBounds, X, Y) then
  begin
    if DroppedDown then
      CloseUp
    else
      DropDown;
    Exit;
  end;
  PickField(FieldAt(X));
end;

{ --- The dropped calendar ------------------------------------------------------- }

function TDateTimePicker.DroppedDown: Boolean;
begin
  Result := FPopup <> nil;
end;

procedure TDateTimePicker.DropDown;
var
  Window: TControlWindow;
  Width: LongInt;
  Height: LongInt;
begin
  if (FPopup <> nil) or not Editable or (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  FinishTyping;
  Window := TControlWindow(Host.OwnerWindow);
  FCalendar := nil;
  FPopup := TPopupWindow.CreatePopup(Window, Window.ScreenLeft + Unscaled(PixelBounds.Left),
    Window.ScreenTop + Unscaled(PixelBounds.Bottom), 10, 10);
  FPopup.OnDismiss := @CalendarDismissed;
  FCalendar := TPickerCalendar.Create(FPopup.Root);
  FCalendar.FPicker := Self;
  FCalendar.MinDate := FMinDate;
  FCalendar.MaxDate := FMaxDate;
  FCalendar.Date := FValue.Date;
  FCalendar.GetPreferredSize(Width, Height);
  FPopup.SetClientSize(Width, Height);
  FCalendar.Align := AlignClient;
  FCalendar.OnDatePicked := @CalendarPicked;
  FCalendar.SetFocus;
  FPopup.Popup;
  Invalidate;
  if Assigned(FOnDropDown) then
    FOnDropDown(Self);
end;

procedure TDateTimePicker.CloseUp;
begin
  if FPopup <> nil then
    FPopup.Dismiss;
end;

procedure TDateTimePicker.CalendarDismissed(Sender: TControl);
begin
  FPopup := nil;
  FCalendar := nil;
  Invalidate;
  if Assigned(FOnCloseUp) then
    FOnCloseUp(Self);
end;

procedure TDateTimePicker.CalendarPicked(Sender: TControl);
var
  Parts: TDateTimeParts;
begin
  Parts := FValue;
  Parts.Date := TCalendar(Sender).Date;
  CloseUp;
  ChangeValue(Parts);
end;

{ --- Painting ------------------------------------------------------------------- }

procedure TDateTimePicker.PaintFields(var Canvas: TCanvas; const Box: TRectangle);
var
  Index: LongInt;
  Left: LongInt;
  Width: LongInt;
  TextTop: LongInt;
  Shown: string;
  Highlight: TRectangle;
begin
  TextTop := (RectangleHeight(Box) - TextHeight(ControlFace)) div 2;
  if not Editable then
  begin
    DrawDisabledText(Canvas, ControlFace, ValueText, FieldsLeft, TextTop);
    Exit;
  end;
  Left := FieldsLeft;
  for Index := 0 to High(FFields) do
  begin
    Shown := FieldText(FFields[Index], FValue);
    Width := TextWidth(ControlFace, Shown);
    if (Index = FFieldIndex) and Focused and not DroppedDown then
    begin
      Highlight := MakeRectangle(Left, TextTop, Width, TextHeight(ControlFace));
      FillRectangle(Canvas, Highlight, Theme.Selection);
      DrawTextInBox(Canvas, ControlFace, Shown, MakeRectangle(Left, TextTop, 1 shl 20, TextHeight(ControlFace)),
        AlignTextLeft, Theme.SelectionText);
    end
    else
      DrawTextInBox(Canvas, ControlFace, Shown, MakeRectangle(Left, TextTop, 1 shl 20, TextHeight(ControlFace)),
        AlignTextLeft, Theme.FieldText);
    Left := Left + Width;
  end;
end;

procedure TDateTimePicker.Paint(var Canvas: TCanvas);
const
  States: array[Boolean] of TCheckState = (CheckUnchecked, CheckChecked);
var
  Box: TRectangle;
  Inner: TCanvas;
  Button: TRectangle;
  Right: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if Enabled then
    FillRectangle(Canvas, Box, Theme.Field)
  else
    FillRectangle(Canvas, Box, Theme.Face);
  DrawBevel(Canvas, Box, SunkenThemeBevel);
  if ControlFace = nil then
    Exit;
  Button := ButtonBounds;
  Right := RectangleWidth(Box) - 2;
  if HasDateFields then
  begin
    DrawButtonFace(Canvas, Button, DroppedDown, False);
    DrawSpinArrow(Canvas, Button, False, Enabled and FChecked);
    Right := Button.Left;
  end
  else if FSpin <> nil then
    Right := Button.Left;
  if FShowCheckBox then
    DrawCheckMark(Canvas, CheckBoxBounds, States[FChecked], Enabled);
  Inner := Canvas;
  NarrowCanvasClip(Inner, MakeRectangle(2, 2, Right - 2, RectangleHeight(Box) - 4));
  PaintFields(Inner, Box);
  if Focused and FShowCheckBox and (FFieldIndex < 0) then
    DrawFocusFrame(Canvas, InflateRectangle(CheckBoxBounds, Scaled(1)), Theme.FieldText);
end;

end.
