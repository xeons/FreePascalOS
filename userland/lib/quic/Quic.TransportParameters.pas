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
  Transport parameters (RFC 9000 section 18): what each endpoint tells
  the other in the TLS handshake (the quic_transport_parameters
  extension), as a sequence of (identifier, length, value) with
  variable-length integers.

  Decoding checks what the RFC asks for: each parameter at most once,
  values in range (ack_delay_exponent <= 20, max_ack_delay < 2^14,
  max_udp_payload_size >= 1200, active_connection_id_limit >= 2,
  stream counts <= 2^60) and, from a client, none of the parameters
  only a server may send. Unknown parameters (and reserved ones,
  31 * N + 27) are skipped. Any breach is TRANSPORT_PARAMETER_ERROR.
}
unit Quic.TransportParameters;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Quic.ConnectionIds;

type
  TQuicTransportParameters = record
    HasOriginalDestinationConnectionId: Boolean;
    OriginalDestinationConnectionId: TQuicConnectionId;
    { Milliseconds; 0: none. }
    MaxIdleTimeout: QWord;
    HasStatelessResetToken: Boolean;
    StatelessResetToken: TStatelessResetToken;
    MaxUdpPayloadSize: QWord;
    InitialMaxData: QWord;
    InitialMaxStreamDataBidiLocal: QWord;
    InitialMaxStreamDataBidiRemote: QWord;
    InitialMaxStreamDataUni: QWord;
    InitialMaxStreamsBidi: QWord;
    InitialMaxStreamsUni: QWord;
    AckDelayExponent: QWord;
    { Milliseconds. }
    MaxAckDelay: QWord;
    DisableActiveMigration: Boolean;
    HasPreferredAddress: Boolean;
    ActiveConnectionIdLimit: QWord;
    HasInitialSourceConnectionId: Boolean;
    InitialSourceConnectionId: TQuicConnectionId;
    HasRetrySourceConnectionId: Boolean;
    RetrySourceConnectionId: TQuicConnectionId;
  end;

{ The defaults of every parameter (what an absent one means). }
procedure DefaultTransportParameters(out Parameters: TQuicTransportParameters);
function EncodeTransportParameters(constref Parameters: TQuicTransportParameters): TBytes;
{ True when the parameters are well formed; FromServer allows the
  parameters only a server sends. }
function DecodeTransportParameters(Data: PByte; Length: PtrUInt; FromServer: Boolean;
  out Parameters: TQuicTransportParameters): Boolean;

implementation

uses
  Quic.Buffers,
  Quic.Constants,
  Quic.VariableIntegers;

procedure DefaultTransportParameters(out Parameters: TQuicTransportParameters);
begin
  Parameters := Default(TQuicTransportParameters);
  Parameters.MaxUdpPayloadSize := DefaultMaxUdpPayloadSize;
  Parameters.AckDelayExponent := DefaultAckDelayExponent;
  Parameters.MaxAckDelay := DefaultMaxAckDelayMilliseconds;
  Parameters.ActiveConnectionIdLimit := DefaultActiveConnectionIdLimit;
end;

procedure WriteIntegerParameter(var Writer: TQuicWriter; Identifier, Value: QWord);
begin
  Writer.WriteVariable(Identifier);
  Writer.WriteVariable(VariableIntegerLength(Value));
  Writer.WriteVariable(Value);
end;

procedure WriteBytesParameter(var Writer: TQuicWriter; Identifier: QWord; Data: PByte; Length: PtrUInt);
begin
  Writer.WriteVariable(Identifier);
  Writer.WriteVariable(Length);
  Writer.WriteBytes(Data, Length);
end;

function EncodeTransportParameters(constref Parameters: TQuicTransportParameters): TBytes;
var
  Buffer: array[0..511] of Byte;
  Writer: TQuicWriter;
begin
  Result := nil;
  Writer.Initialize(@Buffer[0], SizeOf(Buffer));
  with Parameters do
  begin
    if HasOriginalDestinationConnectionId then
      WriteBytesParameter(Writer, ParameterOriginalDestinationConnectionId, @OriginalDestinationConnectionId.Bytes[0],
        OriginalDestinationConnectionId.Length);
    if MaxIdleTimeout > 0 then
      WriteIntegerParameter(Writer, ParameterMaxIdleTimeout, MaxIdleTimeout);
    if HasStatelessResetToken then
      WriteBytesParameter(Writer, ParameterStatelessResetToken, @StatelessResetToken[0], StatelessResetTokenLength);
    if MaxUdpPayloadSize <> DefaultMaxUdpPayloadSize then
      WriteIntegerParameter(Writer, ParameterMaxUdpPayloadSize, MaxUdpPayloadSize);
    if InitialMaxData > 0 then
      WriteIntegerParameter(Writer, ParameterInitialMaxData, InitialMaxData);
    if InitialMaxStreamDataBidiLocal > 0 then
      WriteIntegerParameter(Writer, ParameterInitialMaxStreamDataBidiLocal, InitialMaxStreamDataBidiLocal);
    if InitialMaxStreamDataBidiRemote > 0 then
      WriteIntegerParameter(Writer, ParameterInitialMaxStreamDataBidiRemote, InitialMaxStreamDataBidiRemote);
    if InitialMaxStreamDataUni > 0 then
      WriteIntegerParameter(Writer, ParameterInitialMaxStreamDataUni, InitialMaxStreamDataUni);
    if InitialMaxStreamsBidi > 0 then
      WriteIntegerParameter(Writer, ParameterInitialMaxStreamsBidi, InitialMaxStreamsBidi);
    if InitialMaxStreamsUni > 0 then
      WriteIntegerParameter(Writer, ParameterInitialMaxStreamsUni, InitialMaxStreamsUni);
    if AckDelayExponent <> DefaultAckDelayExponent then
      WriteIntegerParameter(Writer, ParameterAckDelayExponent, AckDelayExponent);
    if MaxAckDelay <> DefaultMaxAckDelayMilliseconds then
      WriteIntegerParameter(Writer, ParameterMaxAckDelay, MaxAckDelay);
    if DisableActiveMigration then
      WriteBytesParameter(Writer, ParameterDisableActiveMigration, nil, 0);
    if ActiveConnectionIdLimit <> DefaultActiveConnectionIdLimit then
      WriteIntegerParameter(Writer, ParameterActiveConnectionIdLimit, ActiveConnectionIdLimit);
    if HasInitialSourceConnectionId then
      WriteBytesParameter(Writer, ParameterInitialSourceConnectionId, @InitialSourceConnectionId.Bytes[0],
        InitialSourceConnectionId.Length);
    if HasRetrySourceConnectionId then
      WriteBytesParameter(Writer, ParameterRetrySourceConnectionId, @RetrySourceConnectionId.Bytes[0],
        RetrySourceConnectionId.Length);
  end;
  if Writer.Failed then
    Exit;
  SetLength(Result, Writer.Length);
  Move(Buffer[0], Result[0], Writer.Length);
end;

{ An integer parameter's value fills its whole length. }
function ReadIntegerValue(Value: PByte; Length: PtrUInt; out Number: QWord): Boolean;
begin
  Result := (Length > 0) and (DecodeVariableInteger(Value, Length, Number) = Integer(Length));
end;

function DecodeTransportParameters(Data: PByte; Length: PtrUInt; FromServer: Boolean;
  out Parameters: TQuicTransportParameters): Boolean;
var
  Reader: TQuicReader;
  Identifier, ValueLength, Number: QWord;
  Value: PByte;
  Seen: set of 0..31;
  Index: Byte;
begin
  DefaultTransportParameters(Parameters);
  Seen := [];
  Reader.Initialize(Data, Length);
  while not Reader.AtEnd do
  begin
    if not Reader.ReadVariable(Identifier) or not Reader.ReadVariable(ValueLength) or
       not Reader.ReadBytes(ValueLength, Value) then
      Exit(False);
    if Identifier > ParameterRetrySourceConnectionId then
      Continue;
    Index := Byte(Identifier);
    if Index in Seen then
      Exit(False);
    Include(Seen, Index);
    { Only a server sends these. }
    if not FromServer and (Index in [ParameterOriginalDestinationConnectionId, ParameterStatelessResetToken,
      ParameterPreferredAddress, ParameterRetrySourceConnectionId]) then
      Exit(False);
    case Index of
      ParameterOriginalDestinationConnectionId:
        begin
          if not MakeConnectionId(Value, ValueLength, Parameters.OriginalDestinationConnectionId) then
            Exit(False);
          Parameters.HasOriginalDestinationConnectionId := True;
        end;
      ParameterStatelessResetToken:
        begin
          if ValueLength <> StatelessResetTokenLength then
            Exit(False);
          Move(Value^, Parameters.StatelessResetToken[0], StatelessResetTokenLength);
          Parameters.HasStatelessResetToken := True;
        end;
      ParameterDisableActiveMigration:
        begin
          if ValueLength <> 0 then
            Exit(False);
          Parameters.DisableActiveMigration := True;
        end;
      ParameterPreferredAddress:
        { Never used (no migration), but its shape is checked: two
          addresses, a connection ID and a reset token. }
        begin
          if ValueLength < 4 + 2 + 16 + 2 + 1 + StatelessResetTokenLength then
            Exit(False);
          Parameters.HasPreferredAddress := True;
        end;
      ParameterInitialSourceConnectionId:
        begin
          if not MakeConnectionId(Value, ValueLength, Parameters.InitialSourceConnectionId) then
            Exit(False);
          Parameters.HasInitialSourceConnectionId := True;
        end;
      ParameterRetrySourceConnectionId:
        begin
          if not MakeConnectionId(Value, ValueLength, Parameters.RetrySourceConnectionId) then
            Exit(False);
          Parameters.HasRetrySourceConnectionId := True;
        end;
    else
      begin
        if not ReadIntegerValue(Value, ValueLength, Number) then
          Exit(False);
        case Index of
          ParameterMaxIdleTimeout: Parameters.MaxIdleTimeout := Number;
          ParameterMaxUdpPayloadSize:
            begin
              if Number < MinimumDatagramSize then
                Exit(False);
              Parameters.MaxUdpPayloadSize := Number;
            end;
          ParameterInitialMaxData: Parameters.InitialMaxData := Number;
          ParameterInitialMaxStreamDataBidiLocal: Parameters.InitialMaxStreamDataBidiLocal := Number;
          ParameterInitialMaxStreamDataBidiRemote: Parameters.InitialMaxStreamDataBidiRemote := Number;
          ParameterInitialMaxStreamDataUni: Parameters.InitialMaxStreamDataUni := Number;
          ParameterInitialMaxStreamsBidi:
            begin
              if Number > MaximumStreamCount then
                Exit(False);
              Parameters.InitialMaxStreamsBidi := Number;
            end;
          ParameterInitialMaxStreamsUni:
            begin
              if Number > MaximumStreamCount then
                Exit(False);
              Parameters.InitialMaxStreamsUni := Number;
            end;
          ParameterAckDelayExponent:
            begin
              if Number > 20 then
                Exit(False);
              Parameters.AckDelayExponent := Number;
            end;
          ParameterMaxAckDelay:
            begin
              if Number >= 16384 then
                Exit(False);
              Parameters.MaxAckDelay := Number;
            end;
          ParameterActiveConnectionIdLimit:
            begin
              if Number < 2 then
                Exit(False);
              Parameters.ActiveConnectionIdLimit := Number;
            end;
        end;
      end;
    end;
  end;
  Result := True;
end;

end.
