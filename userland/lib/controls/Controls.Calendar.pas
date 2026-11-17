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
  Month calendars: a month as a grid of weeks, to pick a date (or a run
  of dates) from.

  The header has the month and year between buttons to the previous and
  next month; a click on the title zooms out to the months of the year,
  and again to the years of the decade, where a click on a month or a
  year zooms back in. Below are the names of the days, weeks starting
  on FirstDayOfWeek (0 Sunday to 6 Saturday; Monday unless set), the
  six weeks of days, optionally with ISO week numbers before them
  (ShowWeekNumbers), and a line for today (ShowToday), which a click
  goes to. Today (in the program's time zone, Sys.LocalTime) has an
  outline; the selected dates are highlighted; dates of the months
  either side and those beyond MinDate and MaxDate are grey, and those
  beyond the limits cannot be picked. Dates the program names
  (AddBoldDate) are bold.

  A click picks a date; with MaxSelectionCount above 1, Shift and a
  click, or dragging, pick the run of dates from the first one (at most
  MaxSelectionCount). Keys: the arrows move a day or a week, Page Up and
  Page Down a month (with Ctrl a year), Home and End to the first and
  last day of the month; Shift extends the run. In the months and years
  views the arrows move between them, Page Up and Page Down a year or a
  decade, Enter zooms in. Ctrl+Up zooms out. The wheel moves a month (a
  year, a decade). The focus frame is on the date the keys move.

  A new selection is announced (OnDateChanged, and OnChange and
  NotifyChanged as every control does); a date clicked or Enter in the
  days view is also announced as picked (OnDatePicked,
  NotifyDatePicked), which is what closes a date picker's calendar.
}
unit Controls.Calendar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base,
  Controls.AutoRepeat,
  Controls.CalendarDates,
  Controls.CalendarLayout;

type
  TCalendarView = (CalendarViewDays, CalendarViewMonths, CalendarViewYears);

  TCalendar = class(TControl)
  private
    FView: TCalendarView;
    { The month shown (the year in the months view; a year of the decade
      in the years view, the one the keys are on). }
    FShownYear: LongInt;
    FShownMonth: LongInt;
    { The run selected goes from the anchor to the cursor (the date the
      keys move). }
    FAnchor: TCalendarDate;
    FCursor: TCalendarDate;
    FMaxSelectionCount: LongInt;
    FMinDate: TCalendarDate;
    FMaxDate: TCalendarDate;
    FFirstDayOfWeek: LongInt;
    FShowWeekNumbers: Boolean;
    FShowToday: Boolean;
    FToday: TCalendarDate;
    FTodayFixed: Boolean;
    FBoldDates: array of TCalendarDate;
    { A press on a day (dragging picks a run), and on a button. }
    FDraggingDays: Boolean;
    FPressedPart: TCalendarPart;
    FRepeat: TAutoRepeat;
    FOnDateChanged: TControlEvent;
    FOnDatePicked: TControlEvent;
    function Metrics: TCalendarMetrics;
    function PartsLayout: TCalendarLayout;
    function GetSelectionStart: TCalendarDate;
    function GetSelectionEnd: TCalendarDate;
    function GetToday: TCalendarDate;
    procedure SetToday(const Value: TCalendarDate);
    procedure SetDate(const Value: TCalendarDate);
    procedure SetView(Value: TCalendarView);
    procedure SetFirstDayOfWeek(Value: LongInt);
    procedure SetShowWeekNumbers(Value: Boolean);
    procedure SetShowToday(Value: Boolean);
    procedure SetMinDate(const Value: TCalendarDate);
    procedure SetMaxDate(const Value: TCalendarDate);
    procedure SetMaxSelectionCount(Value: LongInt);
    function CellDate(Cell: LongInt): TCalendarDate;
    function IsSelected(const Day: TCalendarDate): Boolean;
    procedure MoveCursor(const Day: TCalendarDate; Extend: Boolean);
    procedure ShowMonthOf(const Day: TCalendarDate);
    procedure MoveShown(Steps: LongInt);
    procedure ButtonRepeated(Sender: TControl);
    procedure CellClicked(Cell: LongInt);
    function DaysKeyDown(Code, Modifiers: LongWord): Boolean;
    function ZoomedKeyDown(Code: LongWord): Boolean;
    procedure PaintHeader(var Canvas: TCanvas; const Parts: TCalendarLayout);
    procedure PaintDays(var Canvas: TCanvas; const Parts: TCalendarLayout);
    procedure PaintMonthsOrYears(var Canvas: TCanvas; const Parts: TCalendarLayout);
    procedure PaintFooter(var Canvas: TCanvas; const Parts: TCalendarLayout);
    procedure PaintCell(var Canvas: TCanvas; const Cell: TRectangle; const Caption: string; Selected, Current, Grey,
      Bold, HasFocusFrame: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure DateChanged; virtual;
    procedure DatePicked; virtual;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { The size it needs, logical units. }
    procedure GetPreferredSize(out Width, Height: LongInt);
    { Selects First to Last (kept within MaxSelectionCount and the
      limits). }
    procedure SelectRange(const First, Last: TCalendarDate);
    procedure AddBoldDate(const Day: TCalendarDate);
    procedure ClearBoldDates;
    function IsBoldDate(const Day: TCalendarDate): Boolean;
    { Shows the month of Date without selecting it. }
    procedure ShowMonth(Year, Month: LongInt);
    { The selected date (the first of a run); setting it selects it
      alone and shows its month. }
    property Date: TCalendarDate read GetSelectionStart write SetDate;
    property SelectionStart: TCalendarDate read GetSelectionStart;
    property SelectionEnd: TCalendarDate read GetSelectionEnd;
    { The date the keys move. }
    property CursorDate: TCalendarDate read FCursor;
    property ShownYear: LongInt read FShownYear;
    property ShownMonth: LongInt read FShownMonth;
    property View: TCalendarView read FView write SetView;
    property MaxSelectionCount: LongInt read FMaxSelectionCount write SetMaxSelectionCount;
    { No date (NoCalendarDate): no limit. }
    property MinDate: TCalendarDate read FMinDate write SetMinDate;
    property MaxDate: TCalendarDate read FMaxDate write SetMaxDate;
    property FirstDayOfWeek: LongInt read FFirstDayOfWeek write SetFirstDayOfWeek;
    property ShowWeekNumbers: Boolean read FShowWeekNumbers write SetShowWeekNumbers;
    property ShowToday: Boolean read FShowToday write SetShowToday;
    { Today in the program's time zone, unless the program sets it. }
    property Today: TCalendarDate read GetToday write SetToday;
    property OnDateChanged: TControlEvent read FOnDateChanged write FOnDateChanged;
    property OnDatePicked: TControlEvent read FOnDatePicked write FOnDatePicked;
  end;

const
  NotifyDatePicked = 5;

{ Today's date in the program's time zone. }
function LocalToday: TCalendarDate;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Bevels,
  Drawing.Shapes,
  Font.Faces,
  Sys.Time,
  Sys.LocalTime,
  Windowing.Theme,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Keys,
  Controls.Text,
  Controls.Buttons;

function LocalToday: TCalendarDate;
var
  Local: TLocalTime;
begin
  DecodeLocalTime(CurrentTime, Local);
  Result := MakeCalendarDate(Local.DateTime.Year, Local.DateTime.Month, Local.DateTime.Day);
end;

constructor TCalendar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FMaxSelectionCount := 1;
  FFirstDayOfWeek := 1;
  FShowToday := True;
  FMinDate := NoCalendarDate;
  FMaxDate := NoCalendarDate;
  FToday := LocalToday;
  FAnchor := FToday;
  FCursor := FToday;
  FShownYear := FToday.Year;
  FShownMonth := FToday.Month;
  FRepeat := TAutoRepeat.Create(Self, @ButtonRepeated);
end;

destructor TCalendar.Destroy;
begin
  FRepeat.Free;
  inherited Destroy;
end;

{ --- Measures ------------------------------------------------------------------- }

function TCalendar.Metrics: TCalendarMetrics;
begin
  Result.LineHeight := TextHeight(ControlFace);
  Result.Gap := Scaled(2);
  Result.WeekColumnWidth := 0;
  if FShowWeekNumbers then
    Result.WeekColumnWidth := TextWidth(ControlFace, '00') + Scaled(8);
  Result.ShowsDays := FView = CalendarViewDays;
  Result.ShowsToday := FShowToday;
end;

function TCalendar.PartsLayout: TCalendarLayout;
begin
  Result := ComputeCalendarLayout(InflateRectangle(MakeRectangle(0, 0, RectangleWidth(PixelBounds),
    RectangleHeight(PixelBounds)), -2), Metrics);
end;

procedure TCalendar.GetPreferredSize(out Width, Height: LongInt);
var
  DaysMetrics: TCalendarMetrics;
  CellWidth: LongInt;
  CellHeight: LongInt;
begin
  DaysMetrics := Metrics;
  DaysMetrics.ShowsDays := True;
  CellWidth := TextWidth(ControlFace, 'Wed') + Scaled(8);
  if CellWidth < TextWidth(ControlFace, '00') + Scaled(14) then
    CellWidth := TextWidth(ControlFace, '00') + Scaled(14);
  CellHeight := TextHeight(ControlFace) + Scaled(4);
  CalendarSizeFor(DaysMetrics, CellWidth, CellHeight, Width, Height);
  Width := Unscaled(Width + 4) + 1;
  Height := Unscaled(Height + 4) + 1;
end;

{ --- State ---------------------------------------------------------------------- }

function TCalendar.GetSelectionStart: TCalendarDate;
begin
  if CompareDates(FAnchor, FCursor) <= 0 then
    Result := FAnchor
  else
    Result := FCursor;
end;

function TCalendar.GetSelectionEnd: TCalendarDate;
begin
  if CompareDates(FAnchor, FCursor) >= 0 then
    Result := FAnchor
  else
    Result := FCursor;
end;

function TCalendar.GetToday: TCalendarDate;
begin
  if not FTodayFixed then
    FToday := LocalToday;
  Result := FToday;
end;

procedure TCalendar.SetToday(const Value: TCalendarDate);
begin
  FToday := Value;
  FTodayFixed := not IsNoDate(Value);
  Invalidate;
end;

function TCalendar.IsSelected(const Day: TCalendarDate): Boolean;
begin
  Result := (CompareDates(Day, GetSelectionStart) >= 0) and (CompareDates(Day, GetSelectionEnd) <= 0);
end;

procedure TCalendar.DateChanged;
begin
  if Assigned(FOnDateChanged) then
    FOnDateChanged(Self);
  Changed;
end;

procedure TCalendar.DatePicked;
begin
  if Assigned(FOnDatePicked) then
    FOnDatePicked(Self);
  Notify(NotifyDatePicked);
end;

procedure TCalendar.ShowMonthOf(const Day: TCalendarDate);
begin
  FShownYear := Day.Year;
  FShownMonth := Day.Month;
end;

procedure TCalendar.ShowMonth(Year, Month: LongInt);
begin
  FShownYear := Year;
  FShownMonth := Month;
  Invalidate;
end;

{ The cursor to Date (within the limits); the anchor with it unless the
  run is extended (as far as MaxSelectionCount allows). }
procedure TCalendar.MoveCursor(const Day: TCalendarDate; Extend: Boolean);
var
  OldStart: TCalendarDate;
  OldEnd: TCalendarDate;
  Target: TCalendarDate;
  Span: LongInt;
begin
  OldStart := GetSelectionStart;
  OldEnd := GetSelectionEnd;
  Target := ClampDate(Day, FMinDate, FMaxDate);
  if Extend and (FMaxSelectionCount > 1) then
  begin
    Span := DayNumberOf(Target) - DayNumberOf(FAnchor);
    if Span >= FMaxSelectionCount then
      Target := AddDays(FAnchor, FMaxSelectionCount - 1)
    else if Span <= -FMaxSelectionCount then
      Target := AddDays(FAnchor, 1 - FMaxSelectionCount);
    FCursor := Target;
  end
  else
  begin
    FCursor := Target;
    FAnchor := Target;
  end;
  ShowMonthOf(FCursor);
  Invalidate;
  if not SameDate(OldStart, GetSelectionStart) or not SameDate(OldEnd, GetSelectionEnd) then
    DateChanged;
end;

procedure TCalendar.SetDate(const Value: TCalendarDate);
begin
  if not IsValidDate(Value) then
    Exit;
  MoveCursor(Value, False);
end;

procedure TCalendar.SelectRange(const First, Last: TCalendarDate);
begin
  if not IsValidDate(First) or not IsValidDate(Last) then
    Exit;
  MoveCursor(First, False);
  MoveCursor(Last, True);
end;

procedure TCalendar.SetView(Value: TCalendarView);
begin
  FView := Value;
  Invalidate;
end;

procedure TCalendar.SetFirstDayOfWeek(Value: LongInt);
begin
  FFirstDayOfWeek := ((Value mod DaysInWeek) + DaysInWeek) mod DaysInWeek;
  Invalidate;
end;

procedure TCalendar.SetShowWeekNumbers(Value: Boolean);
begin
  FShowWeekNumbers := Value;
  Invalidate;
end;

procedure TCalendar.SetShowToday(Value: Boolean);
begin
  FShowToday := Value;
  Invalidate;
end;

procedure TCalendar.SetMinDate(const Value: TCalendarDate);
begin
  FMinDate := Value;
  if not DateWithin(FCursor, FMinDate, FMaxDate) or not DateWithin(FAnchor, FMinDate, FMaxDate) then
    MoveCursor(FCursor, False);
  Invalidate;
end;

procedure TCalendar.SetMaxDate(const Value: TCalendarDate);
begin
  FMaxDate := Value;
  if not DateWithin(FCursor, FMinDate, FMaxDate) or not DateWithin(FAnchor, FMinDate, FMaxDate) then
    MoveCursor(FCursor, False);
  Invalidate;
end;

procedure TCalendar.SetMaxSelectionCount(Value: LongInt);
begin
  if Value < 1 then
    Value := 1;
  FMaxSelectionCount := Value;
  if Abs(DayNumberOf(FCursor) - DayNumberOf(FAnchor)) >= Value then
    MoveCursor(FCursor, False);
end;

procedure TCalendar.AddBoldDate(const Day: TCalendarDate);
begin
  SetLength(FBoldDates, Length(FBoldDates) + 1);
  FBoldDates[High(FBoldDates)] := Day;
  Invalidate;
end;

procedure TCalendar.ClearBoldDates;
begin
  FBoldDates := nil;
  Invalidate;
end;

function TCalendar.IsBoldDate(const Day: TCalendarDate): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to High(FBoldDates) do
    if SameDate(FBoldDates[Index], Day) then
      Exit(True);
  Result := False;
end;

{ The date of a days cell; the first of the month or of the year of a
  months or years cell. }
function TCalendar.CellDate(Cell: LongInt): TCalendarDate;
begin
  case FView of
    CalendarViewDays: Result := GridCellDate(FShownYear, FShownMonth, FFirstDayOfWeek, Cell);
    CalendarViewMonths: Result := MakeCalendarDate(FShownYear, Cell + 1, 1);
  else
    Result := MakeCalendarDate((FShownYear div 10) * 10 - 1 + Cell, 1, 1);
  end;
end;

{ What the previous and next buttons (and the wheel) do: a month, a
  year or a decade. }
procedure TCalendar.MoveShown(Steps: LongInt);
var
  Shown: TCalendarDate;
begin
  Shown := MakeCalendarDate(FShownYear, FShownMonth, 1);
  case FView of
    CalendarViewDays: Shown := AddMonths(Shown, Steps);
    CalendarViewMonths: Shown := AddYears(Shown, Steps);
  else
    Shown := AddYears(Shown, Steps * 10);
  end;
  if (Shown.Year < 1) or (Shown.Year > 9999) then
    Exit;
  FShownYear := Shown.Year;
  FShownMonth := Shown.Month;
  Invalidate;
end;

procedure TCalendar.ButtonRepeated(Sender: TControl);
begin
  if FPressedPart = CalendarPartPrevious then
    MoveShown(-1)
  else if FPressedPart = CalendarPartNext then
    MoveShown(1);
end;

{ --- Input ---------------------------------------------------------------------- }

procedure TCalendar.CellClicked(Cell: LongInt);
var
  Day: TCalendarDate;
begin
  Day := CellDate(Cell);
  case FView of
    CalendarViewDays:
      begin
        if not DateWithin(Day, FMinDate, FMaxDate) then
          Exit;
        MoveCursor(Day, (HeldModifiers and ModifierShift) <> 0);
        FDraggingDays := True;
      end;
    CalendarViewMonths:
      begin
        FShownMonth := Day.Month;
        SetView(CalendarViewDays);
      end;
  else
    begin
      FShownYear := Day.Year;
      SetView(CalendarViewMonths);
    end;
  end;
end;

procedure TCalendar.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Cell: LongInt;
  Part: TCalendarPart;
begin
  if Button <> ButtonLeft then
    Exit;
  Part := CalendarPartAt(PartsLayout, X, Y, Cell);
  case Part of
    CalendarPartPrevious, CalendarPartNext:
      begin
        FPressedPart := Part;
        ButtonRepeated(Self);
        FRepeat.Start;
        Invalidate;
      end;
    CalendarPartTitle:
      if FView = CalendarViewDays then
        SetView(CalendarViewMonths)
      else
        SetView(CalendarViewYears);
    CalendarPartToday:
      begin
        SetView(CalendarViewDays);
        if DateWithin(GetToday, FMinDate, FMaxDate) then
        begin
          MoveCursor(GetToday, False);
          DatePicked;
        end;
      end;
    CalendarPartCell: CellClicked(Cell);
  end;
end;

procedure TCalendar.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Cell: LongInt;
  Day: TCalendarDate;
begin
  if not FDraggingDays or (FMaxSelectionCount <= 1) or (FView <> CalendarViewDays) then
    Exit;
  if CalendarPartAt(PartsLayout, X, Y, Cell) <> CalendarPartCell then
    Exit;
  Day := CellDate(Cell);
  if not SameDate(Day, FCursor) and DateWithin(Day, FMinDate, FMaxDate) then
    MoveCursor(Day, True);
end;

procedure TCalendar.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Cell: LongInt;
  WasDragging: Boolean;
begin
  if Button <> ButtonLeft then
    Exit;
  FRepeat.Stop;
  if FPressedPart <> CalendarPartNone then
  begin
    FPressedPart := CalendarPartNone;
    Invalidate;
  end;
  WasDragging := FDraggingDays;
  FDraggingDays := False;
  if WasDragging and (CalendarPartAt(PartsLayout, X, Y, Cell) = CalendarPartCell) and (FView = CalendarViewDays) then
    DatePicked;
end;

procedure TCalendar.Wheel(Steps: LongInt);
begin
  { Up (away from the user): back in time. }
  MoveShown(-Steps);
end;

function TCalendar.DaysKeyDown(Code, Modifiers: LongWord): Boolean;
var
  Extend: Boolean;
  Target: TCalendarDate;
begin
  Result := True;
  Extend := (Modifiers and ModifierShift) <> 0;
  case Code of
    KeyArrowLeft: Target := AddDays(FCursor, -1);
    KeyArrowRight: Target := AddDays(FCursor, 1);
    KeyArrowUp: Target := AddDays(FCursor, -DaysInWeek);
    KeyArrowDown: Target := AddDays(FCursor, DaysInWeek);
    KeyPageUp:
      if (Modifiers and ModifierControl) <> 0 then
        Target := AddYears(FCursor, -1)
      else
        Target := AddMonths(FCursor, -1);
    KeyPageDown:
      if (Modifiers and ModifierControl) <> 0 then
        Target := AddYears(FCursor, 1)
      else
        Target := AddMonths(FCursor, 1);
    KeyHome: Target := MakeCalendarDate(FCursor.Year, FCursor.Month, 1);
    KeyEnd: Target := MakeCalendarDate(FCursor.Year, FCursor.Month, DaysInMonthOf(FCursor.Year, FCursor.Month));
  else
    begin
      if IsEnterKey(Code) then
      begin
        DatePicked;
        Exit(True);
      end;
      Exit(False);
    end;
  end;
  MoveCursor(Target, Extend);
end;

{ The arrows in the months and years views move the month or the year
  shown; Enter zooms in on it. }
function TCalendar.ZoomedKeyDown(Code: LongWord): Boolean;
var
  Steps: LongInt;
  Shown: TCalendarDate;
begin
  Result := True;
  Steps := 0;
  case Code of
    KeyArrowLeft: Steps := -1;
    KeyArrowRight: Steps := 1;
    KeyArrowUp: Steps := -MonthColumns;
    KeyArrowDown: Steps := MonthColumns;
    KeyPageUp: Steps := -12;
    KeyPageDown: Steps := 12;
  else
    begin
      if not IsEnterKey(Code) then
        Exit(False);
      if FView = CalendarViewYears then
        SetView(CalendarViewMonths)
      else
        SetView(CalendarViewDays);
      Exit;
    end;
  end;
  Shown := MakeCalendarDate(FShownYear, FShownMonth, 1);
  if FView = CalendarViewMonths then
    Shown := AddMonths(Shown, Steps)
  else if (Code = KeyPageUp) or (Code = KeyPageDown) then
    { A decade (Steps is a year's months). }
    Shown := AddYears(Shown, (Steps div 12) * 10)
  else
    Shown := AddYears(Shown, Steps);
  if (Shown.Year >= 1) and (Shown.Year <= 9999) then
  begin
    FShownYear := Shown.Year;
    FShownMonth := Shown.Month;
  end;
  Invalidate;
end;

function TCalendar.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  if (Code = KeyArrowUp) and ((Modifiers and ModifierControl) <> 0) then
  begin
    if FView = CalendarViewDays then
      SetView(CalendarViewMonths)
    else
      SetView(CalendarViewYears);
    Exit(True);
  end;
  if FView = CalendarViewDays then
    Result := DaysKeyDown(Code, Modifiers)
  else
    Result := ZoomedKeyDown(Code);
end;

{ --- Painting ------------------------------------------------------------------- }

{ A pressed button's face moves down and right a pixel. }
function OffsetPressed(const Box: TRectangle; Pressed: Boolean): TRectangle;
begin
  if Pressed then
    Result := OffsetRectangle(Box, 1, 1)
  else
    Result := Box;
end;

{ A small solid triangle pointing left (or right) in the middle of Box. }
procedure DrawSideArrow(const Canvas: TCanvas; const Box: TRectangle; Right, Enabled: Boolean);
var
  Arrow: array[0..2] of TPoint;
  CentreX: LongInt;
  CentreY: LongInt;
  Size: LongInt;
  Color: TColor;
begin
  CentreX := Box.Left + RectangleWidth(Box) div 2;
  CentreY := Box.Top + RectangleHeight(Box) div 2;
  Size := Scaled(4);
  if Right then
  begin
    Arrow[0] := MakePoint(CentreX - Size div 2, CentreY - Size);
    Arrow[1] := MakePoint(CentreX - Size div 2, CentreY + Size + 1);
    Arrow[2] := MakePoint(CentreX + Size div 2 + 1, CentreY);
  end
  else
  begin
    Arrow[0] := MakePoint(CentreX + Size div 2, CentreY - Size);
    Arrow[1] := MakePoint(CentreX + Size div 2, CentreY + Size + 1);
    Arrow[2] := MakePoint(CentreX - Size div 2 - 1, CentreY);
  end;
  if Enabled then
    Color := Theme.FaceText
  else
    Color := Theme.DisabledText;
  FillPolygon(Canvas, Arrow, Color);
end;

procedure TCalendar.PaintCell(var Canvas: TCanvas; const Cell: TRectangle; const Caption: string; Selected, Current,
  Grey, Bold, HasFocusFrame: Boolean);
var
  Face: TRectangle;
  TextColor: TColor;
  Font: PFontFace;
begin
  Face := InflateRectangle(Cell, -1);
  if Selected then
  begin
    FillRectangle(Canvas, Face, Theme.Selection);
    TextColor := Theme.SelectionText;
  end
  else if Grey or not Enabled then
    TextColor := Theme.DisabledText
  else
    TextColor := Theme.FieldText;
  if Current then
    DrawRectangleOutline(Canvas, Face, Theme.DarkShadow);
  if Bold then
    Font := ControlBoldFace
  else
    Font := ControlFace;
  DrawTextInBox(Canvas, Font, Caption, Face, AlignTextCenter, TextColor);
  if HasFocusFrame then
    if Selected then
      DrawFocusFrame(Canvas, InflateRectangle(Face, -1), Theme.SelectionText)
    else
      DrawFocusFrame(Canvas, InflateRectangle(Face, -1), Theme.FieldText);
end;

procedure TCalendar.PaintHeader(var Canvas: TCanvas; const Parts: TCalendarLayout);
var
  Title: string;
  Decade: LongInt;
begin
  FillRectangle(Canvas, Parts.Header, Theme.Face);
  DrawButtonFace(Canvas, Parts.Previous, FPressedPart = CalendarPartPrevious, False);
  DrawButtonFace(Canvas, Parts.Next, FPressedPart = CalendarPartNext, False);
  DrawSideArrow(Canvas, OffsetPressed(Parts.Previous, FPressedPart = CalendarPartPrevious), False, Enabled);
  DrawSideArrow(Canvas, OffsetPressed(Parts.Next, FPressedPart = CalendarPartNext), True, Enabled);
  case FView of
    CalendarViewDays: Title := MonthNames[FShownMonth] + ' ' + IntToStr(FShownYear);
    CalendarViewMonths: Title := IntToStr(FShownYear);
  else
    begin
      Decade := (FShownYear div 10) * 10;
      Title := IntToStr(Decade) + '-' + IntToStr(Decade + 9);
    end;
  end;
  DrawTextInBox(Canvas, ControlBoldFace, Title, Parts.Title, AlignTextCenter, Theme.FaceText);
end;

procedure TCalendar.PaintDays(var Canvas: TCanvas; const Parts: TCalendarLayout);
var
  Column: LongInt;
  Row: LongInt;
  Cell: LongInt;
  Box: TRectangle;
  Day: TCalendarDate;
  Thursday: TCalendarDate;
  Weekday: LongInt;
  OtherMonth: Boolean;
  Current: TCalendarDate;
begin
  Current := GetToday;
  for Column := 0 to DaysInWeek - 1 do
  begin
    Box := CalendarCellBounds(Parts, Column);
    Box.Top := Parts.Weekdays.Top;
    Box.Bottom := Parts.Weekdays.Bottom;
    DrawTextInBox(Canvas, ControlFace, Copy(DayNames[GridColumnDay(FFirstDayOfWeek, Column)], 1, 2), Box,
      AlignTextCenter, Theme.FieldText);
  end;
  DrawLine(Canvas, Parts.Weekdays.Left, Parts.Weekdays.Bottom - 1, Parts.Weekdays.Right - 1,
    Parts.Weekdays.Bottom - 1, Theme.Shadow);
  for Cell := 0 to GridDays - 1 do
  begin
    Day := CellDate(Cell);
    OtherMonth := (Day.Month <> FShownMonth) or (Day.Year <> FShownYear);
    PaintCell(Canvas, CalendarCellBounds(Parts, Cell), IntToStr(Day.Day), IsSelected(Day),
      SameDate(Day, Current), OtherMonth or not DateWithin(Day, FMinDate, FMaxDate), IsBoldDate(Day),
      Focused and SameDate(Day, FCursor));
  end;
  if FShowWeekNumbers then
  begin
    DrawLine(Canvas, Parts.WeekNumbers.Right - 1, Parts.WeekNumbers.Top, Parts.WeekNumbers.Right - 1,
      Parts.WeekNumbers.Bottom - 1, Theme.Shadow);
    for Row := 0 to GridWeeks - 1 do
    begin
      { The week the row's Thursday is in (ISO weeks run Monday to
        Sunday, whichever day the rows start on). }
      Thursday := CellDate(Row * DaysInWeek);
      Weekday := DayOfWeekOf(Thursday);
      Thursday := AddDays(Thursday, (4 - Weekday + DaysInWeek) mod DaysInWeek);
      DrawTextInBox(Canvas, ControlFace, IntToStr(IsoWeekNumber(Thursday)), CalendarWeekNumberBounds(Parts, Row),
        AlignTextCenter, Theme.DisabledText);
    end;
  end;
end;

procedure TCalendar.PaintMonthsOrYears(var Canvas: TCanvas; const Parts: TCalendarLayout);
var
  Cell: LongInt;
  Day: TCalendarDate;
  Current: TCalendarDate;
  Selected: TCalendarDate;
  Caption: string;
  Decade: LongInt;
begin
  Current := GetToday;
  Selected := GetSelectionStart;
  Decade := (FShownYear div 10) * 10;
  for Cell := 0 to MonthColumns * MonthRows - 1 do
  begin
    Day := CellDate(Cell);
    if FView = CalendarViewMonths then
    begin
      Caption := Copy(MonthNames[Day.Month], 1, 3);
      PaintCell(Canvas, CalendarCellBounds(Parts, Cell), Caption, (Selected.Year = Day.Year) and
        (Selected.Month = Day.Month), (Current.Year = Day.Year) and (Current.Month = Day.Month), False, False,
        Focused and (Day.Month = FShownMonth));
    end
    else
    begin
      Caption := IntToStr(Day.Year);
      PaintCell(Canvas, CalendarCellBounds(Parts, Cell), Caption, Selected.Year = Day.Year,
        Current.Year = Day.Year, (Day.Year < Decade) or (Day.Year > Decade + 9), False,
        Focused and (Day.Year = FShownYear));
    end;
  end;
end;

procedure TCalendar.PaintFooter(var Canvas: TCanvas; const Parts: TCalendarLayout);
var
  Line: TRectangle;
  Current: TCalendarDate;
begin
  Current := GetToday;
  DrawLine(Canvas, Parts.Footer.Left + Scaled(2), Parts.Footer.Top, Parts.Footer.Right - Scaled(2) - 1,
    Parts.Footer.Top, Theme.Shadow);
  Line := Parts.Footer;
  Line.Top := Line.Top + 1;
  DrawTextInBox(Canvas, ControlFace, 'Today: ' + DateToIsoText(Current), Line, AlignTextCenter, Theme.FieldText);
end;

procedure TCalendar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Parts: TCalendarLayout;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawBevel(Canvas, Box, SunkenThemeBevel);
  if ControlFace = nil then
    Exit;
  Parts := PartsLayout;
  PaintHeader(Canvas, Parts);
  if FView = CalendarViewDays then
    PaintDays(Canvas, Parts)
  else
    PaintMonthsOrYears(Canvas, Parts);
  if FShowToday then
    PaintFooter(Canvas, Parts);
end;

end.
