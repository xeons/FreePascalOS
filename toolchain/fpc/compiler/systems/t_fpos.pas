{
    Copyright (c) 1998-2008 by Peter Vreman
    Copyright (C) 2026 Brandon Scott

    This unit implements support import, export and link routines for
    FreePascalOS (x86-64 and AArch64). It is part of the FreePascalOS
    patches to the Free Pascal compiler.

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 ****************************************************************************
}
{ Linking for FreePascalOS.

  A program is a position independent executable (ET_DYN with an entry
  point and no interpreter: the kernel's loader binds it); a library is
  a shared object whose references to its own symbols are bound when it
  is linked. Both carry a System V hash table (DT_HASH), which is what
  the loader searches. Programs start in the si_prc unit, libraries in
  si_dll (DT_INIT FPC_SHARED_LIB_START, DT_FINI FPC_LIB_EXIT).

  The runtime library and the system's other libraries are shared
  objects in /lib. Their units are marked as living in a library (see
  ppumove, toolchain/fpc), so with -XD a program links against
  libsystem.so instead of the units' object files.

  Two linkers are provided: the compiler's internal ELF linker (x86-64,
  the default there), and GNU ld (-Xe, and AArch64, for which release
  3.2.2 has no internal linker). }
unit t_fpos;

{$i fpcdefs.inc}

interface

  uses
    globtype,
    aasmdata,
    symsym,
    import,export,expunix,link;

  type
    TImportLibFreePascalOS=class(timportlib)
      procedure generatelib;override;
    end;

    TExportLibFreePascalOS=class(texportlibunix)
      procedure setfininame(list: TAsmList; const s: string); override;
    end;

    TLinkerFreePascalOS=class(texternallinker)
    private
      function  WriteResponseFile(isdll:boolean) : boolean;
    public
      constructor Create;override;
      procedure SetDefaultInfo;override;
      procedure InitSysInitUnitName;override;
      function  MakeExecutable:boolean;override;
      function  MakeSharedLibrary:boolean;override;
    end;

    TInternalLinkerFreePascalOS=class(TInternalLinker)
    private
      procedure AddLibraryStatement(const name:TCmdStr);
      procedure AddSectionStatements;
    public
      constructor Create;override;
      procedure DefaultLinkScript;override;
      procedure InitSysInitUnitName;override;
    end;

implementation

  uses
    SysUtils,
    cutils,cfileutl,cclasses,
    verbose,systems,globals,
    cscript,
    fmodule,
    aasmbase,aasmtai,aasmcpu,cpubase,
    cgbase,ogbase,
    ogelf,owar,
    i_fpos
    ;

  const
    { The startup units of programs and of libraries. }
    StartupUnitNames: array[boolean] of string[8] = ('si_prc','si_dll');

{*****************************************************************************
                          Imports and exports
*****************************************************************************}

    procedure TImportLibFreePascalOS.generatelib;
      var
        i : longint;
        ImportLibrary : TImportLibrary;
      begin
        for i:=0 to current_module.ImportLibraryList.Count-1 do
          begin
            ImportLibrary:=TImportLibrary(current_module.ImportLibraryList[i]);
            current_module.linkothersharedlibs.add(ImportLibrary.Name,link_always);
          end;
      end;


    procedure TExportLibFreePascalOS.setfininame(list: TAsmList; const s: string);
      begin
        { without a .fini section, a finalization routine in regular code
          could be smart linked away: reference it like the debug
          information does }
        new_section(list,sec_fpc,'links',0);
        list.concat(Tai_const.Createname(s,0));
        inherited setfininame(list,s);
      end;


{*****************************************************************************
                          Library search path
*****************************************************************************}

    { The system's libraries are in /lib (below the system root when
      cross compiling with -XR). }
    procedure SetupLibrarySearchPath;
      begin
        if not Dontlinkstdlibpath then
          LibrarySearchPath.AddLibraryPath(sysrootpath,'=/lib',true);
      end;


{*****************************************************************************
                          GNU ld
*****************************************************************************}

    constructor TLinkerFreePascalOS.Create;
      begin
        inherited Create;
        SetupLibrarySearchPath;
      end;


    procedure TLinkerFreePascalOS.SetDefaultInfo;
      const
        CommonOptions = '--hash-style=sysv -z max-page-size=4096 -z noexecstack';
      begin
        with Info do
          begin
            ExeCmd[1]:='ld $OPT -pie --no-dynamic-linker '+CommonOptions+
              ' $STRIP $GCSECTIONS $MAP -e _start -L. -o $EXE $RES';
            DllCmd[1]:='ld $OPT -shared -Bsymbolic '+CommonOptions+
              ' $INIT $FINI $SONAME $STRIP $GCSECTIONS $MAP -L. -o $EXE $RES';
            DynamicLinker:='';
          end;
      end;


    procedure TLinkerFreePascalOS.InitSysInitUnitName;
      begin
        sysinitunit:=StartupUnitNames[current_module.islibrary];
      end;


    { link.res is an implicit linker script: the search directories, the
      object files and the libraries (as -l<name>), and for a library
      that names its exports, a version script keeping everything else
      local. }
    function TLinkerFreePascalOS.WriteResponseFile(isdll:boolean) : boolean;
      var
        linkres : TLinkRes;
        HPath   : TCmdStrListItem;
        s       : TCmdStr;
      begin
        result:=false;
        linkres:=TLinkRes.Create(outputexedir+Info.ResName,true);
        with linkres do
          begin
            HPath:=TCmdStrListItem(current_module.locallibrarysearchpath.First);
            while assigned(HPath) do
              begin
                Add('SEARCH_DIR("'+HPath.Str+'")');
                HPath:=TCmdStrListItem(HPath.Next);
              end;
            HPath:=TCmdStrListItem(LibrarySearchPath.First);
            while assigned(HPath) do
              begin
                Add('SEARCH_DIR("'+HPath.Str+'")');
                HPath:=TCmdStrListItem(HPath.Next);
              end;

            if isdll and not texportlibunix(exportlib).exportedsymnames.empty then
              begin
                Add('VERSION');
                Add('{');
                Add('  {');
                Add('    global:');
                repeat
                  Add('      '+texportlibunix(exportlib).exportedsymnames.getfirst+';');
                until texportlibunix(exportlib).exportedsymnames.empty;
                Add('    local:');
                Add('      *;');
                Add('  };');
                Add('}');
              end;

            StartSection('INPUT(');
            while not ObjectFiles.Empty do
              begin
                s:=ObjectFiles.GetFirst;
                if s<>'' then
                  AddFileName(maybequoted(s));
              end;
            EndSection(')');

            if not StaticLibFiles.Empty then
              begin
                Add('GROUP(');
                while not StaticLibFiles.Empty do
                  AddFileName(maybequoted(StaticLibFiles.GetFirst));
                Add(')');
              end;

            if not SharedLibFiles.Empty then
              begin
                Add('INPUT(');
                while not SharedLibFiles.Empty do
                  begin
                    s:=SharedLibFiles.GetFirst;
                    if pos(target_info.sharedlibext,s)>0 then
                      AddFileName(maybequoted(s))
                    else
                      Add('-l'+s);
                  end;
                Add(')');
              end;
            writetodisk;
            Free;
          end;
        result:=true;
      end;


    function TLinkerFreePascalOS.MakeExecutable:boolean;
      var
        binstr,
        cmdstr,
        mapstr,
        StripStr,
        GCSectionsStr : TCmdStr;
        success : boolean;
      begin
        if not(cs_link_nolink in current_settings.globalswitches) then
          Message1(exec_i_linking,current_module.exefilename);

        StripStr:='';
        GCSectionsStr:='';
        mapstr:='';
        if (cs_link_strip in current_settings.globalswitches) then
          StripStr:='-s';
        if (cs_link_map in current_settings.globalswitches) then
          mapstr:='-Map '+maybequoted(ChangeFileExt(current_module.exefilename,'.map'));
        if (cs_link_smart in current_settings.globalswitches) and
           create_smartlink_sections then
          GCSectionsStr:='--gc-sections';

        WriteResponseFile(false);

        SplitBinCmd(Info.ExeCmd[1],binstr,cmdstr);
        Replace(cmdstr,'$EXE',maybequoted(current_module.exefilename));
        Replace(cmdstr,'$OPT',Info.ExtraOptions);
        Replace(cmdstr,'$RES',maybequoted(outputexedir+Info.ResName));
        Replace(cmdstr,'$STRIP',StripStr);
        Replace(cmdstr,'$GCSECTIONS',GCSectionsStr);
        Replace(cmdstr,'$MAP',mapstr);
        if HasExports then
          cmdstr:=cmdstr+' -E';
        success:=DoExec(FindUtil(utilsprefix+binstr),cmdstr,true,false);

        if success and not(cs_link_nolink in current_settings.globalswitches) then
          DeleteFile(outputexedir+Info.ResName);
        MakeExecutable:=success;
      end;


    function TLinkerFreePascalOS.MakeSharedLibrary:boolean;
      var
        binstr,
        cmdstr,
        mapstr,
        StripStr,
        GCSectionsStr : TCmdStr;
        success : boolean;
      begin
        if not(cs_link_nolink in current_settings.globalswitches) then
          Message1(exec_i_linking,current_module.sharedlibfilename);

        StripStr:='';
        GCSectionsStr:='';
        mapstr:='';
        if (cs_link_strip in current_settings.globalswitches) then
          StripStr:='-s';
        if (cs_link_map in current_settings.globalswitches) then
          mapstr:='-Map '+maybequoted(ChangeFileExt(current_module.sharedlibfilename,'.map'));
        if (cs_link_smart in current_settings.globalswitches) and
           create_smartlink_sections then
          GCSectionsStr:='--gc-sections';

        WriteResponseFile(true);

        SplitBinCmd(Info.DllCmd[1],binstr,cmdstr);
        Replace(cmdstr,'$EXE',maybequoted(current_module.sharedlibfilename));
        Replace(cmdstr,'$OPT',Info.ExtraOptions);
        Replace(cmdstr,'$RES',maybequoted(outputexedir+Info.ResName));
        Replace(cmdstr,'$INIT','-init FPC_SHARED_LIB_START');
        Replace(cmdstr,'$FINI','-fini FPC_LIB_EXIT');
        Replace(cmdstr,'$SONAME','-soname '+ExtractFileName(current_module.sharedlibfilename));
        Replace(cmdstr,'$STRIP',StripStr);
        Replace(cmdstr,'$GCSECTIONS',GCSectionsStr);
        Replace(cmdstr,'$MAP',mapstr);
        success:=DoExec(FindUtil(utilsprefix+binstr),cmdstr,true,false);

        if success and not(cs_link_nolink in current_settings.globalswitches) then
          DeleteFile(outputexedir+Info.ResName);
        MakeSharedLibrary:=success;
      end;


{*****************************************************************************
                          The internal ELF linker
*****************************************************************************}

    constructor TInternalLinkerFreePascalOS.Create;
      begin
        inherited Create;
        SetupLibrarySearchPath;
        CArObjectReader:=TArObjectReader;
        CExeOutput:=ElfExeOutputClass;
        CObjInput:=TElfObjInput;
      end;


    procedure TInternalLinkerFreePascalOS.InitSysInitUnitName;
      begin
        sysinitunit:=StartupUnitNames[current_module.islibrary];
      end;


    { A library named by -l or $LINKLIB: lib<name>.so, else lib<name>.a. }
    procedure TInternalLinkerFreePascalOS.AddLibraryStatement(const name:TCmdStr);
      var
        filename,
        foundfile : TCmdStr;
      begin
        if pos(target_info.sharedClibext+'.',name)>0 then
          filename:=target_info.sharedClibprefix+name
        else
          filename:=target_info.sharedClibprefix+name+target_info.sharedClibext;
        if (not(cs_link_staticflag in current_settings.globalswitches)) and
           FindLibraryFile(filename,'','',foundfile) then
          LinkScript.Concat('READSTATICLIBRARY '+maybequoted(foundfile))
        else if FindLibraryFile(name,target_info.staticClibprefix,target_info.staticClibext,foundfile) then
          LinkScript.Concat('READSTATICLIBRARY '+maybequoted(foundfile))
        else
          Comment(V_Error,'Import library not found for '+name);
      end;


    procedure TInternalLinkerFreePascalOS.DefaultLinkScript;
      begin
        { Programs are position independent and need no interpreter. }
        TElfExeOutput(exeoutput).interpreter:=stringdup('');
        TElfExeOutput(exeoutput).PositionIndependentExecutable:=not IsSharedLibrary;
        { Segments are aligned to the page size, as GNU ld's
          -z max-page-size=4096 does for the system's own files. }
        ElfTarget.max_page_size:=$1000;

        ScriptAddSourceStatements(false);
        while not SharedLibFiles.Empty do
          AddLibraryStatement(SharedLibFiles.GetFirst);

        if IsSharedLibrary then
          LinkScript.Concat('ISSHAREDLIBRARY')
        else
          LinkScript.Concat('ENTRYNAME _start');

        AddSectionStatements;
      end;


    { The layout of the output: the read-only parts (headers, dynamic
      symbols, relocations, code, constants) in the first segment, the
      writable ones in the second, as for Linux. }
    procedure TInternalLinkerFreePascalOS.AddSectionStatements;
      var
        relprefix : TCmdStr;
      begin
        if ElfTarget.relocs_use_addend then
          relprefix:='rela'
        else
          relprefix:='rel';
        with LinkScript do
          begin
            Concat('HEADER');
            Concat('EXESECTION .interp');
            Concat('  OBJSECTION .interp');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .note.gnu.build-id');
            Concat('  OBJSECTION .note.gnu.build-id');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .hash');
            Concat('  OBJSECTION .hash');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .dynsym');
            Concat('  OBJSECTION .dynsym');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .dynstr');
            Concat('  OBJSECTION .dynstr');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .gnu.version');
            Concat('  OBJSECTION .gnu.version');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .gnu.version_d');
            Concat('  OBJSECTION .gnu.version_d');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .gnu.version_r');
            Concat('  OBJSECTION .gnu.version_r');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .'+relprefix+'.dyn');
            Concat('  OBJSECTION .'+relprefix+'.dyn');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .'+relprefix+'.plt');
            Concat('  OBJSECTION .'+relprefix+'.plt');
            Concat('  PROVIDE __'+relprefix+'_iplt_start');
            Concat('  OBJSECTION .'+relprefix+'.iplt');
            Concat('  PROVIDE __'+relprefix+'_iplt_end');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .init');
            Concat('  OBJSECTION .init');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .plt');
            Concat('  OBJSECTION .plt');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .text');
            Concat('  OBJSECTION .text*');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .fini');
            Concat('  OBJSECTION .fini');
            Concat('  PROVIDE __etext');
            Concat('  PROVIDE _etext');
            Concat('  PROVIDE etext');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .rodata');
            Concat('  OBJSECTION .rodata*');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .eh_frame');
            Concat('  OBJSECTION .eh_frame');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .gcc_except_table');
            Concat('  OBJSECTION .gcc_except_table');
            Concat('  OBJSECTION .gcc_except_table.*');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .tdata');
            Concat('  OBJSECTION .tdata');
            Concat('  OBJSECTION .tdata.*');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .tbss');
            Concat('  OBJSECTION .tbss');
            Concat('  OBJSECTION .tbss.*');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .preinit_array');
            Concat('  PROVIDE __preinit_array_start');
            Concat('  OBJSECTION .preinit_array');
            Concat('  PROVIDE __preinit_array_end');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .init_array');
            Concat('  PROVIDE __init_array_start');
            Concat('  OBJSECTION .init_array');
            Concat('  PROVIDE __init_array_end');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .fini_array');
            Concat('  PROVIDE __fini_array_start');
            Concat('  OBJSECTION .fini_array');
            Concat('  PROVIDE __fini_array_end');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .ctors');
            Concat('  OBJSECTION .ctors*');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .dtors');
            Concat('  OBJSECTION .dtors*');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .dynamic');
            Concat('  OBJSECTION .dynamic');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .got');
            Concat('  OBJSECTION .got');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .got.plt');
            Concat('  OBJSECTION .got.plt');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .data');
            Concat('  OBJSECTION .data*');
            Concat('  OBJSECTION .fpc*');
            Concat('  OBJSECTION fpc.resources');
            Concat('  PROVIDE _edata');
            Concat('  PROVIDE edata');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .bss');
            Concat('  OBJSECTION .dynbss');
            Concat('  OBJSECTION .bss*');
            Concat('  OBJSECTION fpc.reshandles');
            Concat('  PROVIDE end');
            Concat('  SYMBOL _end');
            Concat('ENDEXESECTION');

            ScriptAddGenericSections('.debug_aranges,.debug_pubnames,.debug_info,'+
               '.debug_abbrev,.debug_line,.debug_frame,.debug_str,.debug_loc,'+
               '.debug_macinfo,.debug_weaknames,.debug_funcnames,.debug_typenames,.debug_varnames,.debug_ranges');
            Concat('EXESECTION .stab');
            Concat('  OBJSECTION .stab');
            Concat('ENDEXESECTION');
            Concat('EXESECTION .stabstr');
            Concat('  OBJSECTION .stabstr');
            Concat('ENDEXESECTION');
          end;
      end;


{*****************************************************************************
                                  Initialize
*****************************************************************************}

initialization
  RegisterLinker(ld_freepascalos,TLinkerFreePascalOS);
  RegisterLinker(ld_int_freepascalos,TInternalLinkerFreePascalOS);
{$ifdef x86_64}
  RegisterImport(system_x86_64_freepascalos,TImportLibFreePascalOS);
  RegisterExport(system_x86_64_freepascalos,TExportLibFreePascalOS);
  RegisterTarget(system_x86_64_freepascalos_info);
{$endif x86_64}
{$ifdef aarch64}
  RegisterImport(system_aarch64_freepascalos,TImportLibFreePascalOS);
  RegisterExport(system_aarch64_freepascalos,TExportLibFreePascalOS);
  RegisterTarget(system_aarch64_freepascalos_info);
{$endif aarch64}
end.
