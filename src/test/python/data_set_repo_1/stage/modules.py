#
# This file is licensed under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
from smv import SmvModule

from abcmod import ABCMod

class OldModule(SmvModule):
    def requiresDS(self): return []
    def run(self, i): return None

class CompileOnceA(SmvModule):
    def requiresDS(self): return []
    def run(self, i): return None

class CompileOnceB(SmvModule):
    def requiresDS(self): return []
    def run(self, i): return None

class ImplMod(ABCMod):
    pass
