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
  Host test of the timesync service's SNTP code (make sntp-test):
    - TimeSync.Packets: NTP timestamps to and from nanoseconds since
      1970 (now, 2040 in era 1, fractions), a request's header, replies
      refused (short, not from a server, not ours, a kiss of death, an
      unsynchronized server, no time) and the offset and delay of one
      with known times;
    - TimeSync.Corrections: the sample with the shortest round trip,
      dead band, step and slew, the poll interval;
    - against sntp-server.py on 127.0.0.1 (its ports in the file given):
      requests over UDP as the service sends them find the server's
      clock 1234.5 s ahead to within 50 ms, with a short round trip,
      and its second port's kiss of death is recognized.
  Prints every failed check and exits with 1 if there was one.

    SntpTest <port-file>
}
program SntpTest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  BaseUnix,
  Unix,
  Sockets,
  TimeSync.Packets,
  TimeSync.Corrections;

const
  NanosecondsPerSecond = Int64(1000000000);
  NanosecondsPerMillisecond = Int64(1000000);
  ServerOffsetNanoseconds = Int64(1234500000000);
  ToleranceNanoseconds = 50 * NanosecondsPerMillisecond;

var
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('FAILED: ', What);
    Inc(Failures);
  end;
end;

function NowNanoseconds: Int64;
var
  Time: TTimeVal;
begin
  fpgettimeofday(@Time, nil);
  Result := Int64(Time.tv_sec) * NanosecondsPerSecond + Int64(Time.tv_usec) * 1000;
end;

procedure CheckTimestamps;
const
  { 2026-11-20 12:00:00.123456789 and 2040-01-01 (era 1). }
  Recent = Int64(1795176000) * NanosecondsPerSecond + 123456789;
  EraOne = Int64(2208988800) * NanosecondsPerSecond + 500000000;
var
  Back: Int64;
begin
  Back := NtpTimestampToNanoseconds(NanosecondsToNtpTimestamp(Recent));
  Check(Abs(Back - Recent) <= 1, Format('2026 round trip (%d ns off)', [Back - Recent]));
  Check((NanosecondsToNtpTimestamp(Recent) shr 32) = QWord(1795176000 + 2208988800),
    'seconds since 1900');
  Back := NtpTimestampToNanoseconds(NanosecondsToNtpTimestamp(EraOne));
  Check(Abs(Back - EraOne) <= 1, Format('2040 (era 1) round trip (%d ns off)', [Back - EraOne]));
  Check((NanosecondsToNtpTimestamp(EraOne) shr 32) < (QWord(1) shl 31), 'era 1 wraps the seconds');
  Check((NanosecondsToNtpTimestamp(NanosecondsPerSecond div 2) and $FFFFFFFF) = $80000000, 'half a second fraction');
end;

procedure CheckRequestAndReplies;
var
  Request: TNtpPacket;
  Reply: TNtpPacket;
  Sent: QWord;
  Sample: TSntpSample;
  T1: Int64;
begin
  T1 := Int64(1795176000) * NanosecondsPerSecond;
  BuildRequest(Request, T1, Sent);
  Check(Request[0] = $23, 'request is version 4, mode 3');
  Check(Sent = NanosecondsToNtpTimestamp(T1), 'request carries its send time');
  { The server 1.5 s ahead, 1 ms between receiving and replying, 10 ms on the wire. }
  BuildReply(Request, T1 + 1500 * NanosecondsPerMillisecond + 5 * NanosecondsPerMillisecond,
    T1 + 1500 * NanosecondsPerMillisecond + 6 * NanosecondsPerMillisecond, 2, Reply);
  Check(ParseReply(Reply, NtpPacketLength, Sent, T1, T1 + 11 * NanosecondsPerMillisecond, Sample) = ReplyAccepted,
    'a good reply is accepted');
  Check(Abs(Sample.OffsetNanoseconds - 1500 * NanosecondsPerMillisecond) <= 2,
    Format('offset of a known reply (%d ns)', [Sample.OffsetNanoseconds]));
  Check(Abs(Sample.DelayNanoseconds - 10 * NanosecondsPerMillisecond) <= 2,
    Format('delay of a known reply (%d ns)', [Sample.DelayNanoseconds]));
  Check(Sample.Stratum = 2, 'stratum');
  Check(ParseReply(Reply, 40, Sent, T1, T1, Sample) = ReplyTooShort, 'a short reply is refused');
  Check(ParseReply(Reply, NtpPacketLength, Sent + 1, T1, T1, Sample) = ReplyNotOurs, 'another request''s reply is refused');
  Reply[0] := (Reply[0] and not 7) or 3;
  Check(ParseReply(Reply, NtpPacketLength, Sent, T1, T1, Sample) = ReplyNotFromServer, 'a client''s packet is refused');
  BuildReply(Request, T1, T1, 0, Reply);
  Check(ParseReply(Reply, NtpPacketLength, Sent, T1, T1, Sample) = ReplyKissOfDeath, 'a kiss of death is told apart');
  BuildReply(Request, T1, T1, 16, Reply);
  Check(ParseReply(Reply, NtpPacketLength, Sent, T1, T1, Sample) = ReplyUnsynchronized, 'stratum 16 is refused');
  BuildReply(Request, T1, T1, 2, Reply);
  Reply[0] := Reply[0] or $C0;
  Check(ParseReply(Reply, NtpPacketLength, Sent, T1, T1, Sample) = ReplyUnsynchronized, 'leap indicator 3 is refused');
  BuildReply(Request, T1, T1, 2, Reply);
  FillChar(Reply[40], 8, 0);
  Check(ParseReply(Reply, NtpPacketLength, Sent, T1, T1, Sample) = ReplyWithoutTime, 'a reply without time is refused');
end;

procedure CheckCorrections;
var
  Samples: TSampleArray;
begin
  Samples := nil;
  Check(BestSample(Samples) = -1, 'no samples, no best');
  SetLength(Samples, 3);
  Samples[0].DelayNanoseconds := 30;
  Samples[1].DelayNanoseconds := 10;
  Samples[2].DelayNanoseconds := 20;
  Check(BestSample(Samples) = 1, 'the shortest round trip wins');
  Check(DecideCorrection(500000, True, 128) = CorrectionNone, 'under the dead band nothing changes');
  Check(DecideCorrection(-2 * NanosecondsPerMillisecond, True, 128) = CorrectionStep, 'the first correction steps');
  Check(DecideCorrection(50 * NanosecondsPerMillisecond, False, 128) = CorrectionSlew, 'a small offset slews');
  Check(DecideCorrection(-200 * NanosecondsPerMillisecond, False, 128) = CorrectionStep, 'a large offset steps');
  Check(NextPollSeconds(64, True, False, 64, 1024) = 128, 'a good poll doubles the interval');
  Check(NextPollSeconds(1024, True, False, 64, 1024) = 1024, 'up to the longest');
  Check(NextPollSeconds(512, True, True, 64, 1024) = 64, 'a step starts again from the shortest');
  Check(NextPollSeconds(256, False, False, 64, 1024) = 128, 'a failed poll halves it');
end;

{ One exchange with 127.0.0.1:Port as the service does it. }
function AskLocalServer(Port: Word; out Sample: TSntpSample): TReplyVerdict;
var
  Socket: LongInt;
  Address: TInetSockAddr;
  Request: TNtpPacket;
  Reply: TNtpPacket;
  Sent: QWord;
  T1: Int64;
  T4: Int64;
  Received: SizeInt;
  Ready: TFDSet;
  Timeout: TTimeVal;
begin
  Result := ReplyWithoutTime;
  FillChar(Sample, SizeOf(Sample), 0);
  Socket := fpSocket(AF_INET, SOCK_DGRAM, 0);
  if Socket < 0 then
    Exit;
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := htons(Port);
  Address.sin_addr := StrToNetAddr('127.0.0.1');
  T1 := NowNanoseconds;
  BuildRequest(Request, T1, Sent);
  fpSendTo(Socket, @Request[0], SizeOf(Request), 0, @Address, SizeOf(Address));
  fpFD_ZERO(Ready);
  fpFD_SET(Socket, Ready);
  Timeout.tv_sec := 2;
  Timeout.tv_usec := 0;
  if fpSelect(Socket + 1, @Ready, nil, nil, @Timeout) > 0 then
  begin
    Received := fpRecv(Socket, @Reply[0], SizeOf(Reply), 0);
    T4 := NowNanoseconds;
    if Received > 0 then
      Result := ParseReply(Reply, Received, Sent, T1, T4, Sample);
  end;
  CloseSocket(Socket);
end;

function ReadFirstLine(const FileName: string): string;
var
  Input: TextFile;
begin
  Result := '';
  AssignFile(Input, FileName);
  Reset(Input);
  if not Eof(Input) then
    ReadLn(Input, Result);
  CloseFile(Input);
end;

procedure CheckAgainstServer(const PortFile: string);
var
  Line: string;
  Space: Integer;
  NormalPort: Word;
  KissPort: Word;
  Samples: TSampleArray;
  Sample: TSntpSample;
  Round: Integer;
  Best: Integer;
begin
  Line := Trim(ReadFirstLine(PortFile));
  Space := Pos(' ', Line);
  NormalPort := StrToIntDef(Copy(Line, 1, Space - 1), 0);
  KissPort := StrToIntDef(Copy(Line, Space + 1, MaxInt), 0);
  Samples := nil;
  for Round := 1 to 4 do
    if AskLocalServer(NormalPort, Sample) = ReplyAccepted then
    begin
      SetLength(Samples, Length(Samples) + 1);
      Samples[High(Samples)] := Sample;
    end;
  Check(Length(Samples) = 4, Format('the local server answered %d of 4 requests', [Length(Samples)]));
  Best := BestSample(Samples);
  if Best >= 0 then
  begin
    Check(Abs(Samples[Best].OffsetNanoseconds - ServerOffsetNanoseconds) < ToleranceNanoseconds,
      Format('the server''s clock is 1234.5 s ahead (found %.3f s)', [Samples[Best].OffsetNanoseconds / 1e9]));
    Check((Samples[Best].DelayNanoseconds >= 0) and (Samples[Best].DelayNanoseconds < ToleranceNanoseconds),
      Format('short round trip (%.3f ms)', [Samples[Best].DelayNanoseconds / 1e6]));
    Check(Samples[Best].Stratum = 2, 'the server''s stratum');
    Check(DecideCorrection(Samples[Best].OffsetNanoseconds, False, DefaultStepThresholdMilliseconds) = CorrectionStep,
      'an offset of 20 minutes is stepped');
  end;
  Check(AskLocalServer(KissPort, Sample) = ReplyKissOfDeath, 'the second port''s kiss of death');
  Check(Sample.ReferenceId = $52415445, 'its code is RATE');
end;

begin
  CheckTimestamps;
  CheckRequestAndReplies;
  CheckCorrections;
  if ParamCount >= 1 then
    CheckAgainstServer(ParamStr(1))
  else
    WriteLn('(no server port file: the exchange over UDP is not tested)');
  if Failures > 0 then
  begin
    WriteLn('SNTP TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('SNTP TEST PASSED');
end.
