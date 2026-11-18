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
  EFI_HTTP_PROTOCOL and its service binding (UEFI specification,
  section 29.6): the firmware's HTTP client, created as a child of a
  network interface.
}
unit Uefi.Http;

{$mode objfpc}

interface

uses
  Uefi.Base;

const
  { EFI_HTTP_VERSION }
  HttpVersion11 = 1;
  { EFI_HTTP_METHOD }
  HttpMethodGet = 0;
  { EFI_HTTP_STATUS_CODE (an enumeration, not the numbers themselves). }
  HttpStatus200Ok = 3;
  HttpStatus404NotFound = 21;

  HttpServiceBindingProtocolGuid: TEfiGuid = (
    Data1: $BDC8E6AF; Data2: $D9BC; Data3: $4379;
    Data4: ($A7, $2A, $E0, $C4, $E7, $5D, $AE, $1C));

  HttpProtocolGuid: TEfiGuid = (
    Data1: $7A59B29B; Data2: $910B; Data3: $4171;
    Data4: ($82, $42, $A8, $5A, $0D, $F2, $5B, $5B));

type
  TEfiIpv4Address = array[0..3] of Byte;

  TEfiHttpv4AccessPoint = record
    UseDefaultAddress: Byte;
    LocalAddress: TEfiIpv4Address;
    LocalSubnet: TEfiIpv4Address;
    LocalPort: Word;
  end;
  PEfiHttpv4AccessPoint = ^TEfiHttpv4AccessPoint;

  TEfiHttpConfigData = record
    HttpVersion: LongWord;
    TimeOutMilliseconds: LongWord;
    LocalAddressIsIpv6: Byte;
    Ipv4Node: PEfiHttpv4AccessPoint;
  end;
  PEfiHttpConfigData = ^TEfiHttpConfigData;

  TEfiHttpRequestData = record
    Method: LongWord;
    Url: PWideChar;
  end;
  PEfiHttpRequestData = ^TEfiHttpRequestData;

  TEfiHttpResponseData = record
    StatusCode: LongWord;
  end;
  PEfiHttpResponseData = ^TEfiHttpResponseData;

  TEfiHttpHeader = record
    FieldName: PChar;
    FieldValue: PChar;
  end;
  PEfiHttpHeader = ^TEfiHttpHeader;

  { Data is the request (sending) or the response (receiving). }
  TEfiHttpMessage = record
    Data: Pointer;
    HeaderCount: QWord;
    Headers: PEfiHttpHeader;
    BodyLength: QWord;
    Body: Pointer;
  end;
  PEfiHttpMessage = ^TEfiHttpMessage;

  TEfiHttpToken = record
    Event: TEfiEvent;
    Status: TEfiStatus;
    Message: PEfiHttpMessage;
  end;
  PEfiHttpToken = ^TEfiHttpToken;

  PEfiHttpProtocol = ^TEfiHttpProtocol;

  TEfiHttpConfigure = function(This: PEfiHttpProtocol; ConfigData: PEfiHttpConfigData): TEfiStatus;
  TEfiHttpTransfer = function(This: PEfiHttpProtocol; Token: PEfiHttpToken): TEfiStatus;
  TEfiHttpPoll = function(This: PEfiHttpProtocol): TEfiStatus;

  TEfiHttpProtocol = record
    GetModeData: Pointer;
    Configure: TEfiHttpConfigure;
    Request: TEfiHttpTransfer;
    Cancel: TEfiHttpTransfer;
    Response: TEfiHttpTransfer;
    Poll: TEfiHttpPoll;
  end;

  PEfiServiceBindingProtocol = ^TEfiServiceBindingProtocol;

  TEfiCreateChild = function(This: PEfiServiceBindingProtocol; ChildHandle: PEfiHandle): TEfiStatus;
  TEfiDestroyChild = function(This: PEfiServiceBindingProtocol; ChildHandle: TEfiHandle): TEfiStatus;

  TEfiServiceBindingProtocol = record
    CreateChild: TEfiCreateChild;
    DestroyChild: TEfiDestroyChild;
  end;

implementation

end.
