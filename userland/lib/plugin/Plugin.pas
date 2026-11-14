{
  A small library that the tests load at run time with LoadLibrary and
  call through FindSymbol. Its entry points have plain C-style names.
}
unit Plugin;

{$mode objfpc}

interface

function PluginAdd(First, Second: Int64): Int64;
function PluginGreeting: PChar;

implementation

function PluginAdd(First, Second: Int64): Int64; [public, alias: 'plugin_add'];
begin
  Result := First + Second;
end;

function PluginGreeting: PChar; [public, alias: 'plugin_greeting'];
begin
  Result := 'hello from libplugin';
end;

end.
