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
  RTT estimation and congestion control (RFC 9002 sections 5 and 7):

  - the RTT estimator: the latest sample, min_rtt, smoothed_rtt and
    rttvar, the peer's ack delay taken off (up to max_ack_delay once the
    handshake is confirmed) when that does not go below min_rtt;
  - NewReno: slow start from ten datagrams (at most 14720 bytes),
    congestion avoidance adding a datagram per window, a recovery
    period that starts with each loss (halving the window, never below
    two datagrams) and ends with the first acknowledgement of a packet
    sent after it, and persistent congestion (losses spanning three
    PTOs) dropping the window to the minimum;
  - pacing: a budget of bytes that refills at 5/4 of the window per
    smoothed RTT, bursts of up to ten datagrams.

  Times are milliseconds.
}
unit Quic.Congestion;

{$mode objfpc}

interface

type
  TQuicRttEstimator = record
    HasSample: Boolean;
    LatestRtt: Int64;
    MinimumRtt: Int64;
    SmoothedRtt: Int64;
    RttVariance: Int64;
  end;

  TQuicCongestionControl = record
    DatagramSize: Int64;
    CongestionWindow: Int64;
    BytesInFlight: Int64;
    SlowStartThreshold: Int64;
    { Packets sent before this time are in the recovery period (-1:
      none yet). }
    RecoveryStartTime: Int64;
    { Pacing. }
    PacingBudget: Int64;
    PacingUpdated: Int64;
  end;

procedure InitializeRtt(out Estimator: TQuicRttEstimator);
procedure UpdateRtt(var Estimator: TQuicRttEstimator; Sample, AckDelay: Int64; HandshakeConfirmed: Boolean;
  MaxAckDelay: Int64);
{ The probe timeout's base (without max_ack_delay and backoff). }
function ProbeTimeoutBase(constref Estimator: TQuicRttEstimator): Int64;

procedure InitializeCongestion(out Control: TQuicCongestionControl; DatagramSize: Int64);
function CongestionAllows(constref Control: TQuicCongestionControl; Bytes: Int64): Boolean;
procedure OnPacketSentCongestion(var Control: TQuicCongestionControl; Bytes: Int64);
procedure OnPacketAcknowledgedCongestion(var Control: TQuicCongestionControl; Bytes, TimeSent: Int64);
{ A packet left the flight without an acknowledgement or a loss (its
  keys were discarded). }
procedure RemoveFromFlight(var Control: TQuicCongestionControl; Bytes: Int64);
{ A loss of a packet sent at TimeSent (the newest lost one), noticed
  at Now. }
procedure OnCongestionEvent(var Control: TQuicCongestionControl; TimeSent, Now: Int64);
procedure OnPersistentCongestion(var Control: TQuicCongestionControl);

{ True when pacing lets Bytes go now; else Wait says how long until it
  does. }
function PacingAllows(var Control: TQuicCongestionControl; constref Estimator: TQuicRttEstimator; Bytes, Now: Int64;
  out Wait: Int64): Boolean;
procedure OnPacketPaced(var Control: TQuicCongestionControl; Bytes: Int64);

implementation

uses
  Quic.Constants;

procedure InitializeRtt(out Estimator: TQuicRttEstimator);
begin
  Estimator := Default(TQuicRttEstimator);
  Estimator.SmoothedRtt := InitialRttMilliseconds;
  Estimator.RttVariance := InitialRttMilliseconds div 2;
end;

procedure UpdateRtt(var Estimator: TQuicRttEstimator; Sample, AckDelay: Int64; HandshakeConfirmed: Boolean;
  MaxAckDelay: Int64);
var
  Adjusted, Difference: Int64;
begin
  if Sample < 0 then
    Sample := 0;
  Estimator.LatestRtt := Sample;
  if not Estimator.HasSample then
  begin
    Estimator.HasSample := True;
    Estimator.MinimumRtt := Sample;
    Estimator.SmoothedRtt := Sample;
    Estimator.RttVariance := Sample div 2;
    Exit;
  end;
  if Sample < Estimator.MinimumRtt then
    Estimator.MinimumRtt := Sample;
  if HandshakeConfirmed and (AckDelay > MaxAckDelay) then
    AckDelay := MaxAckDelay;
  Adjusted := Sample;
  if Sample >= Estimator.MinimumRtt + AckDelay then
    Adjusted := Sample - AckDelay;
  Difference := Estimator.SmoothedRtt - Adjusted;
  if Difference < 0 then
    Difference := -Difference;
  Estimator.RttVariance := (3 * Estimator.RttVariance + Difference) div 4;
  Estimator.SmoothedRtt := (7 * Estimator.SmoothedRtt + Adjusted) div 8;
end;

function ProbeTimeoutBase(constref Estimator: TQuicRttEstimator): Int64;
var
  Variance: Int64;
begin
  Variance := 4 * Estimator.RttVariance;
  if Variance < TimerGranularityMilliseconds then
    Variance := TimerGranularityMilliseconds;
  Result := Estimator.SmoothedRtt + Variance;
end;

function MinimumWindow(constref Control: TQuicCongestionControl): Int64;
begin
  Result := 2 * Control.DatagramSize;
end;

procedure InitializeCongestion(out Control: TQuicCongestionControl; DatagramSize: Int64);
var
  Window: Int64;
begin
  Control := Default(TQuicCongestionControl);
  Control.DatagramSize := DatagramSize;
  Window := 10 * DatagramSize;
  if Window > 14720 then
    Window := 14720;
  if Window < 2 * DatagramSize then
    Window := 2 * DatagramSize;
  Control.CongestionWindow := Window;
  Control.SlowStartThreshold := High(Int64);
  Control.RecoveryStartTime := -1;
  Control.PacingBudget := 10 * DatagramSize;
  Control.PacingUpdated := -1;
end;

function CongestionAllows(constref Control: TQuicCongestionControl; Bytes: Int64): Boolean;
begin
  Result := Control.BytesInFlight + Bytes <= Control.CongestionWindow;
end;

procedure OnPacketSentCongestion(var Control: TQuicCongestionControl; Bytes: Int64);
begin
  Control.BytesInFlight := Control.BytesInFlight + Bytes;
end;

procedure RemoveFromFlight(var Control: TQuicCongestionControl; Bytes: Int64);
begin
  Control.BytesInFlight := Control.BytesInFlight - Bytes;
  if Control.BytesInFlight < 0 then
    Control.BytesInFlight := 0;
end;

procedure OnPacketAcknowledgedCongestion(var Control: TQuicCongestionControl; Bytes, TimeSent: Int64);
begin
  RemoveFromFlight(Control, Bytes);
  { No growth for packets sent before the recovery period started. }
  if (Control.RecoveryStartTime >= 0) and (TimeSent <= Control.RecoveryStartTime) then
    Exit;
  if Control.CongestionWindow < Control.SlowStartThreshold then
    Control.CongestionWindow := Control.CongestionWindow + Bytes
  else
    Control.CongestionWindow := Control.CongestionWindow + (Control.DatagramSize * Bytes) div
      Control.CongestionWindow;
end;

procedure OnCongestionEvent(var Control: TQuicCongestionControl; TimeSent, Now: Int64);
begin
  { One reduction per recovery period. }
  if (Control.RecoveryStartTime >= 0) and (TimeSent <= Control.RecoveryStartTime) then
    Exit;
  Control.RecoveryStartTime := Now;
  Control.SlowStartThreshold := Control.CongestionWindow div 2;
  if Control.SlowStartThreshold < MinimumWindow(Control) then
    Control.SlowStartThreshold := MinimumWindow(Control);
  Control.CongestionWindow := Control.SlowStartThreshold;
end;

procedure OnPersistentCongestion(var Control: TQuicCongestionControl);
begin
  Control.CongestionWindow := MinimumWindow(Control);
  Control.RecoveryStartTime := -1;
end;

function PacingAllows(var Control: TQuicCongestionControl; constref Estimator: TQuicRttEstimator; Bytes, Now: Int64;
  out Wait: Int64): Boolean;
var
  Rate, Burst: Int64;
begin
  Wait := 0;
  { Without an RTT, or below a millisecond, there is nothing to pace. }
  if not Estimator.HasSample or (Estimator.SmoothedRtt <= 0) then
    Exit(True);
  Burst := 10 * Control.DatagramSize;
  { Bytes per millisecond: 5/4 of the window per smoothed RTT. }
  Rate := (5 * Control.CongestionWindow) div (4 * Estimator.SmoothedRtt);
  if Rate < 1 then
    Rate := 1;
  if Control.PacingUpdated < 0 then
    Control.PacingUpdated := Now;
  if Now > Control.PacingUpdated then
  begin
    Control.PacingBudget := Control.PacingBudget + (Now - Control.PacingUpdated) * Rate;
    if Control.PacingBudget > Burst then
      Control.PacingBudget := Burst;
    Control.PacingUpdated := Now;
  end;
  if Control.PacingBudget >= Bytes then
    Exit(True);
  Wait := (Bytes - Control.PacingBudget + Rate - 1) div Rate;
  if Wait < 1 then
    Wait := 1;
  Result := False;
end;

procedure OnPacketPaced(var Control: TQuicCongestionControl; Bytes: Int64);
begin
  Control.PacingBudget := Control.PacingBudget - Bytes;
  if Control.PacingBudget < -Control.DatagramSize then
    Control.PacingBudget := -Control.DatagramSize;
end;

end.
