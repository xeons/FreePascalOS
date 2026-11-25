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
  Counting the bytes of an operation for its progress callback, and
  stopping it when the callback asks to.
}
unit Archive.Progress;

{$mode objfpc}
{$H+}

interface

uses
  Archive.Entries;

type
  TProgressCounter = class
  private
    FOnProgress: TArchiveProgressEvent;
    FBytesDone: QWord;
  public
    constructor Create(OnProgress: TArchiveProgressEvent; StartingBytes: QWord = 0);
    { Counts Count more bytes and tells the callback; raises
      EArchiveCancelled if it asks to stop. }
    procedure Advance(Count: QWord);
    property BytesDone: QWord read FBytesDone;
  end;

implementation

constructor TProgressCounter.Create(OnProgress: TArchiveProgressEvent; StartingBytes: QWord);
begin
  inherited Create;
  FOnProgress := OnProgress;
  FBytesDone := StartingBytes;
end;

procedure TProgressCounter.Advance(Count: QWord);
var
  Cancel: Boolean;
begin
  Inc(FBytesDone, Count);
  if not Assigned(FOnProgress) then
    Exit;
  Cancel := False;
  FOnProgress(FBytesDone, Cancel);
  if Cancel then
    raise EArchiveCancelled.Create('Cancelled');
end;

end.
