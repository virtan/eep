Erlang Easy Profiling (eep)
===========================

Erlang Easy Profiling (eep) application provides a way to analyze an application performance and call hierarchy.

Main features:
 * no need to modify sources (doesn't need sources at all)
 * no need to stop your running system
 * start and stop collecting runtime data at arbitrary time
 * profile arbitrary module or whole system
 * minimal impact on profiled system performance (unlike [fprof] [6])
 * very informative visualization of time costs and call stacks ([kcachegrind] [7])
 * ability to export call graphs in dot or image format
 * optional process separation
 * based on [dbg] [8] module and built-in low overhead [trace ports] [9]

Limitations:
 * doesn't work with natively compiled code
 * doesn't support sending collected runtime data over network (will appear in future versions)
 * doesn't support parent-child links yet (will appear in future versions)

  [6]: http://www.erlang.org/doc/man/fprof.html
  [7]: http://kcachegrind.sourceforge.net/
  [8]: http://www.erlang.org/doc/man/dbg.html
  [9]: http://www.erlang.org/doc/man/dbg.html#trace_port-2

How to
------

On the target system:

1. Make sure the target system can use eep module (place eep.beam at any code path)
2. Collect runtime data to local file
<pre>
eep:start_file_tracing("file_name"), timer:sleep(60000), eep:stop_tracing().
</pre>
3. Copy $PWD/file_name.trace out from the target system

Outside the target system:

1. Make sure collected runtime data is in current directory
2. Convert to callgrind format
<pre>
eep:convert_tracing("file_name").
</pre>
3. Start kcachegrind
<pre>
$ kcachegrind callgrind.out.file_name
</pre>

Also
----

1. Collect only specific module calls
<pre>
eep:start_file_tracing("file_name", [], my_module).
</pre>
2. Include time spent waiting for event (not running on erts schedulers)
<pre>
eep:convert_tracing("file_name", [waits]).
</pre>
3. Dump collected runtime data
<pre>
eep:dump_tracing("file_name").
</pre>
4. Don't separate by erlang processes
<pre>
$ grep -v "^ob=" callgrind.out.file_name > callgrind.out.merged_file_name
</pre>

Useful
------

* Turn off kcachegrind "cycle detection", eep is trying to detect cycles by itself
* Absolute numbers in kcachegrind are microseconds
* ELF Objects in kcachegrind are erlang pids
* By default kcachegrind limits caller depth and node cost (can be changed in call graph context menu in Graph submenu)

Screenshots
-----------

* [Overall view] [1]
* [Call hierarchy] [2]
* [Functions navigator] [3]
* [Callees ordered by cost] [4]
* [Relative costs view] [5]

  [1]: https://raw.github.com/virtan/eep/master/doc/sshot1.png
  [2]: https://raw.github.com/virtan/eep/master/doc/sshot2.png
  [3]: https://raw.github.com/virtan/eep/master/doc/sshot3.png
  [4]: https://raw.github.com/virtan/eep/master/doc/sshot4.png
  [5]: https://raw.github.com/virtan/eep/master/doc/sshot6.png

Author
------

Igor Milyakov
[virtan@virtan.com] [10]

  [10]: mailto:virtan@virtan.com?subject=Eep

License
-------

The MIT License (MIT)

Copyright (c) 2013 Igor Milyakov virtan@virtan.com

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
