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
  Token buckets: a rate limit that allows bursts. A bucket holds up to
  Burst tokens and gains RatePerSecond of them each second; each event
  takes one, and an event that finds the bucket empty is refused. The
  network stack limits with them the ICMP and ICMPv6 errors it sends
  (RFC 1812 4.3.2.8, RFC 4443 2.4 (f)), the errors it takes in, and
  TCP's challenge ACKs (RFC 5961 7).

  The credit is kept in nanoseconds of refill time, so no division by
  the rate is needed per event. Times are the caller's clock
  (nanoseconds); nothing here reads one. Pure: the host test builds it.
}
unit Network.TokenBuckets;

{$mode objfpc}

interface

const
  TokenBucketNanosecondsPerSecond = QWord(1000000000);

type
  TTokenBucket = record
    { Nanoseconds of refill one token costs, and the most credit kept. }
    TokenCost: QWord;
    CreditLimit: QWord;
    Credit: QWord;
    LastRefill: QWord;
    Started: Boolean;
  end;

procedure InitializeTokenBucket(out Bucket: TTokenBucket; RatePerSecond, Burst: LongWord);
{ True (and a token taken) if the bucket has one at Now. }
function TakeToken(var Bucket: TTokenBucket; Now: QWord): Boolean;

implementation

procedure InitializeTokenBucket(out Bucket: TTokenBucket; RatePerSecond, Burst: LongWord);
begin
  if RatePerSecond = 0 then
    RatePerSecond := 1;
  if Burst = 0 then
    Burst := 1;
  Bucket.TokenCost := TokenBucketNanosecondsPerSecond div RatePerSecond;
  if Bucket.TokenCost = 0 then
    Bucket.TokenCost := 1;
  Bucket.CreditLimit := Bucket.TokenCost * Burst;
  Bucket.Credit := Bucket.CreditLimit;
  Bucket.LastRefill := 0;
  Bucket.Started := False;
end;

function TakeToken(var Bucket: TTokenBucket; Now: QWord): Boolean;
var
  Elapsed: QWord;
begin
  if not Bucket.Started then
  begin
    Bucket.Started := True;
    Bucket.LastRefill := Now;
  end
  else if Now > Bucket.LastRefill then
  begin
    Elapsed := Now - Bucket.LastRefill;
    if Elapsed >= Bucket.CreditLimit - Bucket.Credit then
      Bucket.Credit := Bucket.CreditLimit
    else
      Bucket.Credit := Bucket.Credit + Elapsed;
    Bucket.LastRefill := Now;
  end;
  if Bucket.Credit < Bucket.TokenCost then
    Exit(False);
  Bucket.Credit := Bucket.Credit - Bucket.TokenCost;
  Result := True;
end;

end.
