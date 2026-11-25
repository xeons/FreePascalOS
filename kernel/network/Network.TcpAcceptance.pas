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
  Which arriving segments a synchronized TCP connection believes, as
  numbers only (the state machine, Network.TcpInput, acts on the
  answers):

    * the receive window test of RFC 793 (RFC 9293 3.10.7.4), with its
      allowance for a zero window: a segment at exactly RCV.NXT is
      taken for its ACK and RST even if it carries data, which is then
      cut away;
    * resets (RFC 5961 3.2): one at exactly RCV.NXT ends the
      connection, one elsewhere in the window gets a challenge ACK,
      others are dropped;
    * acknowledgments (RFC 5961 5.2): acceptable from SND.UNA less the
      largest window the peer ever offered up to SND.MAX; one beyond
      SND.MAX acknowledges what was never sent, one below the range is
      too old to be genuine - both get an ACK and go no further.

  Pure: the host test builds it.
}
unit Network.TcpAcceptance;

{$mode objfpc}

interface

type
  TResetDisposition = (ResetDropped, ResetChallenged, ResetAccepted);
  TAcknowledgmentDisposition = (AcknowledgmentAcceptable, AcknowledgmentTooNew, AcknowledgmentTooOld);

const
  { RFC 5961 5.2 needs MAX.SND.WND; a larger one is taken as this so
    that the comparisons stay within half the sequence space. }
  LargestUsableSendWindow = LongWord(1) shl 30;

{ The segment (Sequence, SequenceLength: its data plus SYN and FIN)
  overlaps the window of Window bytes from ReceiveNext. }
function SegmentIsAcceptable(Sequence, SequenceLength, ReceiveNext, Window: LongWord): Boolean;
function ResetDisposition(Sequence, ReceiveNext, Window: LongWord): TResetDisposition;
function AcknowledgmentDisposition(Acknowledgment, SendUnacknowledged, SendMaximum,
  LargestSendWindow: LongWord): TAcknowledgmentDisposition;

implementation

uses
  Network.TcpSequences;

function InWindow(Sequence, ReceiveNext, Window: LongWord): Boolean;
begin
  Result := SequenceAfterOrEqual(Sequence, ReceiveNext) and
    SequenceBefore(Sequence, LongWord(QWord(ReceiveNext) + Window));
end;

function SegmentIsAcceptable(Sequence, SequenceLength, ReceiveNext, Window: LongWord): Boolean;
var
  LastSequence: LongWord;
begin
  if Window = 0 then
    { Nothing fits, but a segment at RCV.NXT still brings its ACK. }
    Exit(Sequence = ReceiveNext);
  if SequenceLength = 0 then
    Exit(InWindow(Sequence, ReceiveNext, Window));
  LastSequence := LongWord(QWord(Sequence) + SequenceLength - 1);
  Result := InWindow(Sequence, ReceiveNext, Window) or InWindow(LastSequence, ReceiveNext, Window);
end;

function ResetDisposition(Sequence, ReceiveNext, Window: LongWord): TResetDisposition;
begin
  if Sequence = ReceiveNext then
    Exit(ResetAccepted);
  if InWindow(Sequence, ReceiveNext, Window) then
    Exit(ResetChallenged);
  Result := ResetDropped;
end;

function AcknowledgmentDisposition(Acknowledgment, SendUnacknowledged, SendMaximum,
  LargestSendWindow: LongWord): TAcknowledgmentDisposition;
var
  OldestAcceptable: LongWord;
begin
  if SequenceAfter(Acknowledgment, SendMaximum) then
    Exit(AcknowledgmentTooNew);
  if LargestSendWindow > LargestUsableSendWindow then
    LargestSendWindow := LargestUsableSendWindow;
  OldestAcceptable := LongWord(QWord(SendUnacknowledged) - LargestSendWindow);
  if SequenceBefore(Acknowledgment, OldestAcceptable) then
    Exit(AcknowledgmentTooOld);
  Result := AcknowledgmentAcceptable;
end;

end.
