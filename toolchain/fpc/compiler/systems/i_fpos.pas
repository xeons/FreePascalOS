{
    Copyright (c) 1998-2008 by Peter Vreman
    Copyright (C) 2026 Brandon Scott

    This unit implements the support information structures for
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
{ FreePascalOS programs and libraries are position independent ELF
  files, dynamically linked against libsystem.so (the runtime library)
  and bound by the kernel's loader. The code generation follows the
  System V ABI exactly as on Linux; only the operating system differs:
  the target defines FREEPASCALOS and neither UNIX nor LINUX, code is
  position independent by default, programs start in si_prc and
  libraries in si_dll. }
unit i_fpos;

{$i fpcdefs.inc}

  interface

    uses
       systems;

    const
       system_x86_64_freepascalos_info : tsysteminfo =
          (
            system       : system_x86_64_freepascalos;
            name         : 'FreePascalOS for x86-64';
            shortname    : 'FreePascalOS';
            flags        : [tf_smartlink_sections,tf_needs_symbol_size,tf_needs_dwarf_cfi,
                            tf_library_needs_pic,tf_needs_symbol_type,tf_files_case_sensitive,
                            tf_has_winlike_resources,tf_safecall_exceptions,tf_safecall_clearstack,
                            tf_pic_default];
            cpu          : cpu_x86_64;
            unit_env     : 'FREEPASCALOSUNITS';
            extradefines : '';
            exeext       : '';
            defext       : '.def';
            scriptext    : '.sh';
            smartext     : '.sl';
            unitext      : '.ppu';
            unitlibext   : '.ppl';
            asmext       : '.s';
            objext       : '.o';
            resext       : '.res';
            resobjext    : '.or';
            sharedlibext : '.so';
            staticlibext : '.a';
            staticlibprefix : 'libp';
            sharedlibprefix : 'lib';
            sharedClibext : '.so';
            staticClibext : '.a';
            staticClibprefix : 'lib';
            sharedClibprefix : 'lib';
            importlibprefix : 'libimp';
            importlibext : '.a';
            Cprefix      : '';
            newline      : #10;
            dirsep       : '/';
            assem        : as_x86_64_elf64;
            assemextern  : as_gas;
            link         : ld_int_freepascalos;
            linkextern   : ld_freepascalos;
            ar           : ar_gnu_ar;
            res          : res_elf;
            dbg          : dbg_dwarf2;
            script       : script_unix;
            endian       : endian_little;
            alignment    :
              (
                procalign       : 16;
                loopalign       : 8;
                jumpalign       : 0;
                constalignmin   : 0;
                constalignmax   : 16;
                varalignmin     : 0;
                varalignmax     : 16;
                localalignmin   : 4;
                localalignmax   : 16;
                recordalignmin  : 0;
                recordalignmax  : 16;
                maxCrecordalign : 16
              );
            first_parm_offset : 16;
            stacksize    : 8*1024*1024;
            stackalign   : 16;
            abi : abi_default;
            llvmdatalayout : 'e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v64:64:64-v128:128:128-a0:0:64-s0:64:64-f80:128:128-n8:16:32:64-S128';
          );

       { Release 3.2.2 has neither an internal assembler nor an internal
         ELF linker for AArch64: GNU as and ld do that work. }
       system_aarch64_freepascalos_info : tsysteminfo =
          (
            system       : system_aarch64_freepascalos;
            name         : 'FreePascalOS for AArch64';
            shortname    : 'FreePascalOS';
            flags        : [tf_needs_symbol_size,
                            tf_needs_symbol_type,
                            tf_files_case_sensitive,
                            tf_requires_proper_alignment,
                            tf_smartlink_sections,tf_pic_uses_got,
                            tf_has_winlike_resources,
                            tf_pic_default];
            cpu          : cpu_aarch64;
            unit_env     : 'FREEPASCALOSUNITS';
            extradefines : '';
            exeext       : '';
            defext       : '.def';
            scriptext    : '.sh';
            smartext     : '.sl';
            unitext      : '.ppu';
            unitlibext   : '.ppl';
            asmext       : '.s';
            objext       : '.o';
            resext       : '.res';
            resobjext    : '.or';
            sharedlibext : '.so';
            staticlibext : '.a';
            staticlibprefix : 'libp';
            sharedlibprefix : 'lib';
            sharedClibext : '.so';
            staticClibext : '.a';
            staticClibprefix : 'lib';
            sharedClibprefix : 'lib';
            importlibprefix : 'libimp';
            importlibext : '.a';
            Cprefix      : '';
            newline      : #10;
            dirsep       : '/';
            assem        : as_gas;
            assemextern  : as_gas;
            link         : ld_none;
            linkextern   : ld_freepascalos;
            ar           : ar_gnu_ar;
            res          : res_elf;
            dbg          : dbg_dwarf2;
            script       : script_unix;
            endian       : endian_little;
            alignment    :
              (
                procalign       : 8;
                loopalign       : 4;
                jumpalign       : 0;
                constalignmin   : 0;
                constalignmax   : 16;
                varalignmin     : 0;
                varalignmax     : 16;
                localalignmin   : 4;
                localalignmax   : 16;
                recordalignmin  : 0;
                recordalignmax  : 16;
                maxCrecordalign : 16
              );
            first_parm_offset : 16;
            stacksize    : 8*1024*1024;
            stackalign   : 16;
            abi : abi_default;
            llvmdatalayout : 'e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v64:64:64-v128:128:128-a0:0:64-n32:64-S128'
          );

  implementation

initialization
{$ifdef cpux86_64}
  {$ifdef freepascalos}
    set_source_info(system_x86_64_freepascalos_info);
  {$endif freepascalos}
{$endif cpux86_64}
{$ifdef cpuaarch64}
  {$ifdef freepascalos}
    set_source_info(system_aarch64_freepascalos_info);
  {$endif freepascalos}
{$endif cpuaarch64}
end.
