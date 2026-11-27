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
  taskmanager - the programs, processes and performance of the system

  taskmanager

  A window with three tabs:

    Programs     the programs with windows, by title: Switch To brings
                 one forward, End Program asks it to end and, if it has
                 not after a few seconds, offers to end it outright
    Processes    every process (this user's, or everybody's): name, id,
                 user, CPU, memory, threads, state, session; sorted by
                 any column; a right click offers End, End now, Stop,
                 Continue, Priority and Properties
    Performance  graphs of how busy the processors were (all together
                 and each one) and of the memory in use over the last
                 minute, and the numbers: processes, threads, up time,
                 what the memory is used for

  It looks every second (View > Update Speed), and remembers its size,
  tab, sort and speed in the user's settings (group TaskManager). The
  desktop opens it from the Start menu, the taskbar's menu and
  Ctrl+Shift+Escape. Prints what happens, a line each:

    settings size W H, tab T, sort C ORDER, update MS   what it starts with
    tab NAME                the tab shown (programs, processes, performance)
    place NAME X Y          where something is on the screen (pixels): the
                            tabs, buttons, the first rows, menu items
    process PID NAME CPU KB the first rows of the Processes list after a look
    program WINDOW PID TITLE  the Programs list, when it changed
    cpu N% memory N%        after each look
    performance cpu N memory N processes N threads N
    graph NAME X Y W H      where a graph is (the Performance tab)
    sort COLUMN ORDER       the list sorted by a click on a header
    asked PID, ended-now PID, ended PID, stopped PID, continued PID,
    priority PID NICE, error TEXT, properties PID NAME THREADS KB
    not-responding PID      a program asked to end still runs
    exit                    the program ends

  The units are in userland/taskmanager: TaskManager.MainWindow (menus,
  tabs, status bar, the update timer), TaskManager.ProgramsPage (and
  TaskManager.ProgramIcons, its windows' icons),
  TaskManager.ProcessesPage, TaskManager.PerformancePage,
  TaskManager.Sampler (the looks and the shares), TaskManager.History,
  TaskManager.UsageGraph, TaskManager.ProcessActions (ending, stopping,
  priorities), TaskManager.EndWatch, TaskManager.PropertiesDialog,
  TaskManager.Formatting, TaskManager.Settings and TaskManager.Output.
}
program TaskManager;

{$mode objfpc}
{$H+}

uses
  Windowing.Windows,
  TaskManager.MainWindow;

var
  Window: TTaskManagerWindow;
begin
  Window := TTaskManagerWindow.Create;
  Window.Show;
  Window.Start;
  RunMessageLoop;
  Window.Free;
end.
