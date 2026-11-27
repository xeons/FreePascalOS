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
  timesync: keeps the wall clock to time servers over SNTP (a service,
  /etc/services/timesync.service, started once the network is).

  Its settings are the system's TimeSync group
  (/etc/settings/TimeSync.settings):
    Enabled = false                 off by default: the service ends at
                                    once, and stays stopped
    Servers = ["pool.ntp.org"]      tried in turn until one answers
                                    (names, addresses, "host:port")
    StepThresholdMilliseconds = 128 offsets beyond it are stepped
    MinimumPollSeconds = 64, MaximumPollSeconds = 1024
  They are read again before every poll. Until the first answer a
  failed poll is tried again soon (2 s, then twice as long each time,
  as the network may still be coming up). The first correction steps the
  clock (CallAdjustWallClock at once, which writes the battery backed
  clock too); later ones slew it unless they are beyond the threshold
  (TimeSync.Corrections). Each poll and correction is a line of its log
  (/var/log/timesync.log).

    timesync --once [SERVER] [--dry-run]
      one poll (of SERVER, or the configured ones), the offset printed
      and, unless --dry-run, the clock corrected; exits 1 if no server
      answered.
}
program TimeSyncService;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Kernel,
  Configuration.Settings,
  Configuration.Locations,
  TimeSync.Packets,
  TimeSync.Corrections,
  TimeSync.Exchange;

const
  DefaultServer = 'pool.ntp.org';
  FirstRetrySeconds = 2;

type
  TTimeSyncSettings = record
    Enabled: Boolean;
    Servers: TStringArray;
    StepThresholdMilliseconds: Int64;
    ShortestPollSeconds: LongInt;
    LongestPollSeconds: LongInt;
  end;

var
  FirstCorrectionDone: Boolean = False;
  NextServer: Integer = 0;

procedure Log(const Text: string);
begin
  WriteLn('timesync: ', Text);
  Flush(Output);
end;

function ReadTimeSyncSettings(Settings: TSettings): TTimeSyncSettings;
var
  Defaults: TStringArray;
begin
  Defaults := nil;
  SetLength(Defaults, 1);
  Defaults[0] := DefaultServer;
  Result.Enabled := Settings.ReadBoolean('TimeSync/Enabled', False);
  Result.Servers := Settings.ReadList('TimeSync/Servers', Defaults);
  if Length(Result.Servers) = 0 then
    Result.Servers := Defaults;
  Result.StepThresholdMilliseconds := Settings.ReadIntegerWithin('TimeSync/StepThresholdMilliseconds',
    DefaultStepThresholdMilliseconds, 1, 3600000);
  Result.ShortestPollSeconds := LongInt(Settings.ReadIntegerWithin('TimeSync/MinimumPollSeconds',
    ShortestPollSeconds, 16, 65536));
  Result.LongestPollSeconds := LongInt(Settings.ReadIntegerWithin('TimeSync/MaximumPollSeconds',
    LongestPollSeconds, Result.ShortestPollSeconds, 65536));
end;

function MillisecondsText(Nanoseconds: Int64): string;
begin
  Result := FormatFloat('0.000', Nanoseconds / 1e6) + ' ms';
end;

{ Asks the servers in turn (starting after the last one that answered);
  True with the best sample. }
function Poll(const Servers: TStringArray; out Best: TSntpSample; out ServerName: string): Boolean;
var
  Tried: Integer;
  Samples: TSampleArray;
  Problem: string;
  Index: Integer;
begin
  Result := False;
  for Tried := 0 to High(Servers) do
  begin
    ServerName := Servers[(NextServer + Tried) mod Length(Servers)];
    if AskTimeServer(ServerName, Samples, Problem) then
    begin
      Index := BestSample(Samples);
      Best := Samples[Index];
      NextServer := (NextServer + Tried) mod Length(Servers);
      Exit(True);
    end;
    Log(ServerName + ': ' + Problem);
  end;
end;

{ Corrects the clock by Sample's offset as the settings say; returns
  whether it stepped. }
function Correct(constref Sample: TSntpSample; StepThreshold: Int64; DryRun: Boolean): Boolean;
var
  Kind: TCorrectionKind;
  Remaining: Int64;
  Flags: LongWord;
  Status: Int64;
begin
  Result := False;
  Kind := DecideCorrection(Sample.OffsetNanoseconds, not FirstCorrectionDone, StepThreshold);
  if Kind = CorrectionNone then
  begin
    FirstCorrectionDone := True;
    Exit;
  end;
  if DryRun then
    Exit;
  if Kind = CorrectionStep then
    Flags := 0
  else
    Flags := AdjustGradually;
  Status := KernelAdjustWallClock(Sample.OffsetNanoseconds, Flags, Remaining);
  if Status < 0 then
  begin
    Log('could not correct the clock (error ' + IntToStr(-Status) + ')');
    Exit;
  end;
  FirstCorrectionDone := True;
  Result := Kind = CorrectionStep;
  if Result then
    Log('stepped the clock by ' + MillisecondsText(Sample.OffsetNanoseconds))
  else
    Log('slewing the clock by ' + MillisecondsText(Sample.OffsetNanoseconds));
end;

function RunOnce(const Server: string; DryRun: Boolean): LongInt;
var
  Settings: TSettings;
  Configured: TTimeSyncSettings;
  Servers: TStringArray;
  Best: TSntpSample;
  ServerName: string;
begin
  Settings := OpenSystemSettings;
  try
    Configured := ReadTimeSyncSettings(Settings);
  finally
    Settings.Free;
  end;
  Servers := nil;
  if Server <> '' then
  begin
    SetLength(Servers, 1);
    Servers[0] := Server;
  end
  else
    Servers := Configured.Servers;
  if not Poll(Servers, Best, ServerName) then
    Exit(1);
  WriteLn(Format('%s: offset %s, delay %s, stratum %d', [ServerName, MillisecondsText(Best.OffsetNanoseconds),
    MillisecondsText(Best.DelayNanoseconds), Best.Stratum]));
  Correct(Best, Configured.StepThresholdMilliseconds, DryRun);
  Result := 0;
end;

procedure RunService;
var
  Settings: TSettings;
  Configured: TTimeSyncSettings;
  PollSeconds: LongInt;
  Best: TSntpSample;
  ServerName: string;
  Answered: Boolean;
  Stepped: Boolean;
  RetrySeconds: LongInt;
begin
  Settings := OpenSystemSettings;
  Configured := ReadTimeSyncSettings(Settings);
  if not Configured.Enabled then
  begin
    Log('disabled (TimeSync/Enabled is false in /etc/settings/TimeSync.settings)');
    Settings.Free;
    Exit;
  end;
  PollSeconds := Configured.ShortestPollSeconds;
  RetrySeconds := FirstRetrySeconds;
  Log('keeping the clock to ' + string.Join(', ', Configured.Servers));
  while True do
  begin
    Configured := ReadTimeSyncSettings(Settings);
    if not Configured.Enabled then
    begin
      Log('disabled; ending');
      Break;
    end;
    Stepped := False;
    Answered := Poll(Configured.Servers, Best, ServerName);
    if Answered then
    begin
      Log(Format('%s: offset %s, delay %s, stratum %d', [ServerName, MillisecondsText(Best.OffsetNanoseconds),
        MillisecondsText(Best.DelayNanoseconds), Best.Stratum]));
      Stepped := Correct(Best, Configured.StepThresholdMilliseconds, False);
    end;
    PollSeconds := NextPollSeconds(PollSeconds, Answered, Stepped, Configured.ShortestPollSeconds,
      Configured.LongestPollSeconds);
    if not Answered and not FirstCorrectionDone and (RetrySeconds < PollSeconds) then
    begin
      { At start the network may still be getting its address: try again
        soon, a little later each time. }
      Sleep(RetrySeconds * 1000);
      RetrySeconds := RetrySeconds * 2;
    end
    else
      Sleep(PollSeconds * 1000);
  end;
  Settings.Free;
end;

var
  Index: Integer;
  Server: string;
  DryRun: Boolean;
  Once: Boolean;
begin
  Once := False;
  DryRun := False;
  Server := '';
  for Index := 1 to ParamCount do
    if ParamStr(Index) = '--once' then
      Once := True
    else if ParamStr(Index) = '--dry-run' then
      DryRun := True
    else if (ParamStr(Index) = '--help') or (ParamStr(Index) = '-h') then
    begin
      WriteLn('usage: timesync [--once [SERVER] [--dry-run]]');
      Halt(0);
    end
    else
      Server := ParamStr(Index);
  if Once then
    Halt(RunOnce(Server, DryRun));
  RunService;
end.
