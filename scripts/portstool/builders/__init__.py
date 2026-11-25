# FreePascalOS
# Copyright (C) 2026 Brandon Scott
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""The build systems, by the name port.toml gives them."""

from .autotools import AutotoolsBuilder
from .cmake import CmakeBuilder
from .custom import CustomBuilder, NoBuilder
from .fpc import FpcBuilder
from .make import MakeBuilder
from .meson import MesonBuilder

BUILDERS = {
    builder.name: builder
    for builder in (AutotoolsBuilder, MesonBuilder, CmakeBuilder, MakeBuilder, FpcBuilder, CustomBuilder, NoBuilder)
}


def builder_for(context):
    return BUILDERS[context.port.build_system](context)
