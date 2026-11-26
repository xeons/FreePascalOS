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
  The permessage-deflate extension (RFC 7692) on a client's side.

  The offer is "permessage-deflate" with no parameters: the client's
  window is the whole 32 KiB its compressor uses, so a server may not
  limit it (client_max_window_bits in the answer is then an error, as
  section 7.1.2.2 says). The server may say server_no_context_takeover,
  client_no_context_takeover and server_max_window_bits (8 to 15; any
  window up to 32 KiB inflates the same).

  A message is compressed as raw deflate data ended by a sync flush,
  whose last four bytes (00 00 FF FF) are left off; decompressing adds
  them back. Without context takeover each message starts afresh.

  Plain Pascal (libcompression), checked on the host by tools/HttpTest.
}
unit Http.WebSocketDeflate;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Compression.Deflater,
  Compression.Inflater;

const
  PerMessageDeflateOffer = 'permessage-deflate';

type
  TPerMessageDeflateParameters = record
    ServerNoContextTakeover: Boolean;
    ClientNoContextTakeover: Boolean;
    { 0: not given (15). }
    ServerMaxWindowBits: Integer;
  end;

  { Compresses the client's messages. }
  TWebSocketCompressor = class
  private
    FDeflater: TDeflater;
    FNoContextTakeover: Boolean;
  public
    constructor Create(NoContextTakeover: Boolean);
    destructor Destroy; override;
    function Compress(Data: Pointer; Count: PtrUInt): TBytes;
  end;

  { Decompresses the server's messages, at most Limit bytes each. }
  TWebSocketDecompressor = class
  private
    FInflater: TInflater;
    FNoContextTakeover: Boolean;
  public
    constructor Create(NoContextTakeover: Boolean);
    destructor Destroy; override;
    { False when the data is not deflate data or inflates past Limit.
      Output may not be the array Data points into (an out parameter is
      emptied before the call). }
    function Decompress(Data: Pointer; Count: PtrUInt; Limit: QWord; out Output: TBytes): Boolean;
  end;

{ The server's Sec-WebSocket-Extensions (all of its fields joined with
  ","): True with Enabled when it is empty or accepts permessage-deflate
  with parameters it may give; False (with the reason) for anything
  else - an extension not offered, one twice, an unknown or repeated
  parameter, a bad value. }
function ParseExtensionsAnswer(const Value: string; out Enabled: Boolean;
  out Parameters: TPerMessageDeflateParameters; out Reason: string): Boolean;

implementation

uses
  Compression.Formats;

const
  SyncTail: array[0..3] of Byte = ($00, $00, $FF, $FF);

constructor TWebSocketCompressor.Create(NoContextTakeover: Boolean);
begin
  inherited Create;
  FDeflater := TDeflater.Create(FormatRaw, CompressionLevelDefault);
  FNoContextTakeover := NoContextTakeover;
end;

destructor TWebSocketCompressor.Destroy;
begin
  FDeflater.Free;
  inherited Destroy;
end;

function TWebSocketCompressor.Compress(Data: Pointer; Count: PtrUInt): TBytes;
var
  Buffer: array[0..16383] of Byte;
  Written, Filled: SizeInt;
  Outcome: TDeflateResult;
begin
  Result := nil;
  Filled := 0;
  FDeflater.SetInput(Data, Count);
  repeat
    Outcome := FDeflater.Compress(@Buffer[0], SizeOf(Buffer), Written, FlushSync);
    if Written > 0 then
    begin
      SetLength(Result, Filled + Written);
      Move(Buffer[0], Result[Filled], Written);
      Inc(Filled, Written);
    end;
  until Outcome = DeflateNeedsInput;
  if (Filled >= 4) and (Result[Filled - 4] = 0) and (Result[Filled - 3] = 0) and (Result[Filled - 2] = $FF) and
     (Result[Filled - 1] = $FF) then
    SetLength(Result, Filled - 4);
  if Length(Result) = 0 then
  begin
    { An empty message is one empty stored block's byte (section 7.2.3.6). }
    SetLength(Result, 1);
    Result[0] := 0;
  end;
  if FNoContextTakeover then
    FDeflater.Reset;
end;

constructor TWebSocketDecompressor.Create(NoContextTakeover: Boolean);
begin
  inherited Create;
  FInflater := TInflater.Create(FormatRaw);
  FNoContextTakeover := NoContextTakeover;
end;

destructor TWebSocketDecompressor.Destroy;
begin
  FInflater.Free;
  inherited Destroy;
end;

function TWebSocketDecompressor.Decompress(Data: Pointer; Count: PtrUInt; Limit: QWord; out Output: TBytes): Boolean;
var
  Buffer: array[0..16383] of Byte;
  Written: SizeInt;
  Filled: QWord;
  Outcome: TInflateResult;
  Pass: Integer;
  Inflated: TBytes;
begin
  Inflated := nil;
  Filled := 0;
  for Pass := 0 to 1 do
  begin
    if Pass = 0 then
    begin
      if Count = 0 then
        Continue;
      FInflater.SetInput(Data, Count);
    end
    else
      FInflater.SetInput(@SyncTail[0], SizeOf(SyncTail));
    repeat
      Outcome := FInflater.Decompress(@Buffer[0], SizeOf(Buffer), Written);
      if Outcome = InflateFailed then
        Exit(False);
      if Written > 0 then
      begin
        if Filled + QWord(Written) > Limit then
          Exit(False);
        SetLength(Inflated, Filled + QWord(Written));
        Move(Buffer[0], Inflated[Filled], Written);
        Inc(Filled, Written);
      end;
    until Outcome <> InflateOutputFull;
    { A final block (some servers end every message so when they keep
      no context): what follows starts a new stream. }
    if Outcome = InflateFinished then
    begin
      FInflater.Reset;
      Break;
    end;
  end;
  if FNoContextTakeover then
    FInflater.Reset;
  Output := Inflated;
  Result := True;
end;

function ParseExtensionsAnswer(const Value: string; out Enabled: Boolean;
  out Parameters: TPerMessageDeflateParameters; out Reason: string): Boolean;
var
  Extensions, Parts: TStringArray;
  Index, PartIndex, Equals, Bits: Integer;
  Name, ParameterName, ParameterValue: string;
  Seen: array[0..2] of Boolean;
begin
  Enabled := False;
  Parameters := Default(TPerMessageDeflateParameters);
  Reason := '';
  Extensions := Value.Split([',']);
  for Index := 0 to High(Extensions) do
  begin
    if Trim(Extensions[Index]) = '' then
      Continue;
    Parts := Extensions[Index].Split([';']);
    Name := LowerCase(Trim(Parts[0]));
    if Name <> 'permessage-deflate' then
    begin
      Reason := 'the server chose an extension not offered: ' + Name;
      Exit(False);
    end;
    if Enabled then
    begin
      Reason := 'permessage-deflate twice';
      Exit(False);
    end;
    Enabled := True;
    Seen[0] := False;
    Seen[1] := False;
    Seen[2] := False;
    for PartIndex := 1 to High(Parts) do
    begin
      Equals := Pos('=', Parts[PartIndex]);
      if Equals > 0 then
      begin
        ParameterName := LowerCase(Trim(Copy(Parts[PartIndex], 1, Equals - 1)));
        ParameterValue := Trim(Copy(Parts[PartIndex], Equals + 1, MaxInt));
        if (Length(ParameterValue) >= 2) and (ParameterValue[1] = '"') and
           (ParameterValue[Length(ParameterValue)] = '"') then
          ParameterValue := Copy(ParameterValue, 2, Length(ParameterValue) - 2);
      end
      else
      begin
        ParameterName := LowerCase(Trim(Parts[PartIndex]));
        ParameterValue := '';
      end;
      if ParameterName = 'server_no_context_takeover' then
      begin
        if Seen[0] or (Equals > 0) then
        begin
          Reason := 'a bad server_no_context_takeover';
          Exit(False);
        end;
        Seen[0] := True;
        Parameters.ServerNoContextTakeover := True;
      end
      else if ParameterName = 'client_no_context_takeover' then
      begin
        if Seen[1] or (Equals > 0) then
        begin
          Reason := 'a bad client_no_context_takeover';
          Exit(False);
        end;
        Seen[1] := True;
        Parameters.ClientNoContextTakeover := True;
      end
      else if ParameterName = 'server_max_window_bits' then
      begin
        if Seen[2] or not TryStrToInt(ParameterValue, Bits) or (Bits < 8) or (Bits > 15) or
           (Length(ParameterValue) > 2) or (ParameterValue[1] = '0') then
        begin
          Reason := 'a bad server_max_window_bits';
          Exit(False);
        end;
        Seen[2] := True;
        Parameters.ServerMaxWindowBits := Bits;
      end
      else
      begin
        { client_max_window_bits was not offered; anything else is
          unknown. }
        Reason := 'a parameter not allowed: ' + ParameterName;
        Exit(False);
      end;
    end;
  end;
  Result := True;
end;

end.
