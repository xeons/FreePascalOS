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
  Choosing among DHCP offers (RFC 2131 4.4.1: the client "may choose to
  wait for multiple responses").

  The client collects the offers that come for a short while after the
  first (OfferWindowMilliseconds) and takes the one offering the address
  it had before, else the first that came. An offer of the address it
  had before ends the wait at once: nothing can be better.
}
unit NetworkService.DhcpOffers;

{$mode objfpc}
{$H+}

interface

uses
  Sys.InternetAddresses,
  NetworkService.DhcpMessages;

const
  OfferWindowMilliseconds = 1000;

type
  TDhcpOfferChoice = record
    HasOffer: Boolean;
    Offer: TDhcpReply;
    { The address had before (HasPreferred False: none). }
    HasPreferred: Boolean;
    Preferred: TInternetAddress;
    { How many offers came. }
    Offers: Integer;
  end;

{ Begins a choice; the offer of Preferred (if HasPreferred) wins. }
procedure BeginOfferChoice(out Choice: TDhcpOfferChoice; HasPreferred: Boolean;
  constref Preferred: TInternetAddress);
{ Takes in an offer (one with an address). }
procedure ConsiderOffer(var Choice: TDhcpOfferChoice; constref Offer: TDhcpReply);
{ True once the chosen offer cannot be bettered (it offers the address
  had before): no need to wait for others. }
function OfferChoiceIsSettled(constref Choice: TDhcpOfferChoice): Boolean;

implementation

procedure BeginOfferChoice(out Choice: TDhcpOfferChoice; HasPreferred: Boolean;
  constref Preferred: TInternetAddress);
begin
  Choice := Default(TDhcpOfferChoice);
  Choice.HasPreferred := HasPreferred;
  Choice.Preferred := Preferred;
end;

function OffersPreferred(constref Choice: TDhcpOfferChoice; constref Offer: TDhcpReply): Boolean;
begin
  Result := Choice.HasPreferred and AddressesAreEqual(Offer.YourAddress, Choice.Preferred);
end;

procedure ConsiderOffer(var Choice: TDhcpOfferChoice; constref Offer: TDhcpReply);
begin
  if AddressIsUnspecified(Offer.YourAddress) then
    Exit;
  Inc(Choice.Offers);
  if not Choice.HasOffer or (OffersPreferred(Choice, Offer) and not OfferChoiceIsSettled(Choice)) then
  begin
    Choice.Offer := Offer;
    Choice.HasOffer := True;
  end;
end;

function OfferChoiceIsSettled(constref Choice: TDhcpOfferChoice): Boolean;
begin
  Result := Choice.HasOffer and OffersPreferred(Choice, Choice.Offer);
end;

end.
