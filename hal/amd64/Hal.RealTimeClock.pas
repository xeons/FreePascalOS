{
  CMOS real-time clock (the battery backed clock of PC compatibles).

  Read once at startup to find the current date and time; the kernel then
  keeps time by counting clock ticks. The clock is assumed to hold UTC.
}
unit Hal.RealTimeClock;

{$mode objfpc}

interface

uses
  Runtime.Time;

{ Returns the current time, or zero if the clock could not be read. }
function ReadRealTimeClock: TUnixTime;

implementation

uses
  Hal.PortIo;

const
  CmosAddressPort = $70;
  CmosDataPort = $71;
  { Keeps NMIs enabled while selecting a register. }
  NmiEnabledMask = $7F;

  RegisterSeconds = $00;
  RegisterMinutes = $02;
  RegisterHours = $04;
  RegisterDayOfMonth = $07;
  RegisterMonth = $08;
  RegisterYear = $09;
  RegisterStatusA = $0A;
  RegisterStatusB = $0B;
  RegisterCentury = $32;

  StatusAUpdateInProgress = $80;
  StatusBBinaryMode = $04;
  StatusB24HourMode = $02;
  HourPmFlag = $80;

  MaximumAttempts = 10;

type
  TClockReading = record
    Second: Byte;
    Minute: Byte;
    Hour: Byte;
    Day: Byte;
    Month: Byte;
    Year: Byte;
    Century: Byte;
  end;

function ReadCmosRegister(Register: Byte): Byte;
begin
  WritePortByte(CmosAddressPort, Register and NmiEnabledMask);
  Result := ReadPortByte(CmosDataPort);
end;

procedure WaitWhileUpdating;
var
  Attempt: Integer;
begin
  for Attempt := 1 to 100000 do
  begin
    if (ReadCmosRegister(RegisterStatusA) and StatusAUpdateInProgress) = 0 then
      Exit;
  end;
end;

procedure TakeReading(out Reading: TClockReading);
begin
  WaitWhileUpdating;
  Reading.Second := ReadCmosRegister(RegisterSeconds);
  Reading.Minute := ReadCmosRegister(RegisterMinutes);
  Reading.Hour := ReadCmosRegister(RegisterHours);
  Reading.Day := ReadCmosRegister(RegisterDayOfMonth);
  Reading.Month := ReadCmosRegister(RegisterMonth);
  Reading.Year := ReadCmosRegister(RegisterYear);
  Reading.Century := ReadCmosRegister(RegisterCentury);
end;

function ReadingsAreEqual(const First, Second: TClockReading): Boolean;
begin
  Result := (First.Second = Second.Second) and (First.Minute = Second.Minute) and
    (First.Hour = Second.Hour) and (First.Day = Second.Day) and
    (First.Month = Second.Month) and (First.Year = Second.Year) and
    (First.Century = Second.Century);
end;

function BcdToBinary(Value: Byte): Byte;
begin
  Result := (Value shr 4) * 10 + (Value and $0F);
end;

function ReadRealTimeClock: TUnixTime;
var
  Reading: TClockReading;
  Confirmation: TClockReading;
  Attempt: Integer;
  StatusB: Byte;
  IsPm: Boolean;
  Year: LongInt;
begin
  { Read until two consecutive readings agree, so an update in the middle
    of a reading cannot produce a mixed result. }
  TakeReading(Reading);
  for Attempt := 1 to MaximumAttempts do
  begin
    TakeReading(Confirmation);
    if ReadingsAreEqual(Reading, Confirmation) then
      Break;
    Reading := Confirmation;
  end;

  StatusB := ReadCmosRegister(RegisterStatusB);
  IsPm := (Reading.Hour and HourPmFlag) <> 0;
  Reading.Hour := Reading.Hour and not HourPmFlag;

  if (StatusB and StatusBBinaryMode) = 0 then
  begin
    Reading.Second := BcdToBinary(Reading.Second);
    Reading.Minute := BcdToBinary(Reading.Minute);
    Reading.Hour := BcdToBinary(Reading.Hour);
    Reading.Day := BcdToBinary(Reading.Day);
    Reading.Month := BcdToBinary(Reading.Month);
    Reading.Year := BcdToBinary(Reading.Year);
    Reading.Century := BcdToBinary(Reading.Century);
  end;

  if ((StatusB and StatusB24HourMode) = 0) then
  begin
    if Reading.Hour = 12 then
      Reading.Hour := 0;
    if IsPm then
      Reading.Hour := Reading.Hour + 12;
  end;

  { The century register is not guaranteed to exist. }
  if (Reading.Century >= 19) and (Reading.Century <= 30) then
    Year := LongInt(Reading.Century) * 100 + Reading.Year
  else
    Year := 2000 + Reading.Year;

  if (Reading.Month < 1) or (Reading.Month > 12) or (Reading.Day < 1) or (Reading.Day > 31) then
    Exit(0);

  Result := CalendarToUnixTime(Year, Reading.Month, Reading.Day,
    Reading.Hour, Reading.Minute, Reading.Second);
end;

end.
