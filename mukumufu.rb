#!/usr/bin/env ruby

# coding: utf-8

=begin
* mukumufu version 2 (一から書き直してテストつけた版) *

このスクリプトの機能はふたつ。

== Makefile.inc.txtの生成 ==

mukumufu.rbを引数なしで起動すると、Makefile.inc.txtを生成する。

  $ ./mukumufu.rb
  > mukumufu.rb

Makefile.inc.txtの内容は以下のとおり：

  ・OBJS = コンパイルが必要なファイル
  ・CFLAGS_INCLUDE_DIRS = #includeするディレクトリのフラグ
  ・hoge.h: fuga.h
  ・hoge.c: hoge.h
  ・hoge.obj: hoge.c

生成はsrcフォルダのmain.cから依存関係をたどって行われる。

仮定しているディレクトリ構成はこんなかんじ。

  src/
    hoge/
      fuga.h
      fuga.c
    foo/
      bar.h
      bar.cpp
      baz.h
      baz.c
    moga.c
    main.c
  mukumufu.rb
  Makefile (ユーザが用意、Makefile.inc.txtを読み込む)
  Makefile.inc.txt (このスクリプトが生成)

つまり、こんなルール。

  ・foo.hがあったらfoo.cかfoo.cppがそのモジュールの本体
  ・フォルダ分けは自由にできるが、ファイル名がかぶってはいけない
    (モジュールの名前は唯一)

後者のルールはいまどき古いとは思うが、名前空間がないC言語に合わせた。

== ソースの関係を調査 ==

mukumufuはソースコードの関係を調べるツールとしても使える。

  mukumufu.rb --list hoge
  mukumufu.rb -l hoge

hogeという名前で始まるソースファイルを一覧する。

  mukumufu.rb --include hoge.h
  mukumufu.rb -i hoge.h

hoge.hが直接または間接に#includeしているファイルを調べる。

== 図の出力 ==

  mukumufu.rb --graph
  mukumufu.rb -g

GraphvizのDOT形式で依存関係を出力する。
=end

require 'enumerator'
require 'kconv'
require 'set'
require 'forwardable'

# requires :each_neighbor method
module Traversable
  def dfs
    visited = Set.new
    stack = [self]
    
    while node = stack.pop
      next if visited.include?(node)
      visited << node
      
      yield node
      
      node.each_neighbor {|x| stack.push x }
    end
    
    visited
  end
end

module Mukumufu

# represents a code file
# Traversable as a node in a dependency tree with SourceList
class Source
  include Traversable
  
  attr_reader :path

  def initialize(list, path, content=nil)
    @list = list
    @path = normalize_path(path)
    @content = content && content.toutf8
  end
  
  def to_s
    @path
  end
  
  def inspect
    sprintf '#<%s:%#x @path="%s", @content=%s>', self.class.name, hash, @path, @content ? '"..."' : 'nil'
  end
  
  def pretty_print(q)
    q.object_group(self) do
      q.breakable
      q.text '@path='
      q.pp @path
      q.comma_breakable
      q.text '@content='
      q.text(@content ? '"..."' : 'nil')
    end
  end
  
  def find_source
    raise ArgumentError, "'#{self}' is not a header" unless !c? && h?
    @list.find_source(name)
  end
  
  # getters
  def content
    @content ||= IO.read(path).toutf8
  end
  
  def name
    basename[0..-extname.size-1]
  end
  
  def basename
    File.basename(path)
  end
  
  def extension
    extname[1..-1]
  end
  
  def dirname
    File.dirname(path)
  end
  alias tree dirname
  
  # preds
  def c?
    path_matches?(/\.(?:m|c(?:c|pp|xx)?)\z/i)
  end
  
  def cxx?
    path_matches?(/\.c(?:c|pp|xx)\z/i)
  end
  
  def h?
    path_matches?(/\.(?:h|hh|hpp|hxx|inc)\z/i)
  end
  
  # traversing
  def each_neighbor(&blk)
    each_depending_header(&blk)
    each_depending_source(&blk)
  end
  
  def each_depending_header(&blk)
    depending_headers.each(&blk)
  end
  
  def each_depending_source(&blk)
    depending_sources.each(&blk)
  end
  
  def depending_headers
    @depending_headers ||= make_depending_headers
  end

  def depending_sources
    @depending_sources ||= make_depending_sources
  end
  
  def depending_header_names
    @depending_header_names ||= scan_includes
  end
  
  def all_related_sources
    dfs {}.to_a
  end
  
  private
  def normalize_path(path)
    path.gsub(/[\/\\]+/, '/')
  end
  
  def path_matches?(matcher)
    matcher === path
  end
  
  def extname
    File.extname(basename)
  end
  
  def make_depending_headers
    hs = depending_header_names.map {|d| @list[d] }
    hs.compact!
    hs
  end
  
  def make_depending_sources
    cs = depending_headers.map {|d| d.find_source }
    cs.compact!
    cs
  end
  
  def scan_includes
    ds = content.scan(/^\s*#\s*(?:include|import)\s*[<"]([^"<>]+)[>"]/i)
    ds.flatten!
    ds
  end
end

# consists of Sources
class SourceList
  include Enumerable

  def initialize(*sources)
    @sources = sources.map {|s| s.is_a?(String) ? Source.new(self, s) : s }
  end
  
  def add(source)
    @sources << source
    self
  end

  def [](name)
    basename = File.basename(name)
    warn "SourceList#[]: #{name}#{' -> ' + basename if name != basename} queried" if $DEBUG
    find_one {|s| s.basename == basename }
  end
  
  def find_source(name)
    find_one {|s| s.name == name && s.c? }
  end
  
  def size
    @sources.size
  end
  
  def empty?
    @sources.empty?
  end

  def each(&blk)
    @sources.each(&blk)
  end
  
  private
  def find_one(&blk)
    srcs = select(&blk)
    
    case srcs.size
    when 0
      nil
    when 1
      srcs[0]
    else
      raise "multiple files found: conflicting\n  #{srcs.join "\n  "}"
    end
  end
end

# SourceList with a root Source node
# Wraps SourceList to provide convenient methods
class SourceTree
  include Enumerable
  extend Forwardable
  
  def_delegators :@list, :each, :[], :size, :empty?
  
  attr_reader :start

  def initialize(dir_or_list, start, globber=Dir)
    if dir_or_list.is_a?(String)
      dir = dir_or_list
      files = globber.glob("#{dir}/**/*.{m,c,cc,cpp,cxx,h,hh,hpp,hxx,inc}")
      dir_or_list = SourceList.new(*files)
    end
    
    @list = dir_or_list

    roots = @list.select {|s| s.name == start || s.path == start || s.basename == start }
    raise ArgumentError, "'#{start}' not found" if roots.empty?

    if roots.size == 1
      @start = roots[0]
    else
      # prefer C file
      cs = roots.select {|s| s.c? }
      raise ArgumentError, "ambiguous name '#{start}':\n  #{roots.join "\n  "}" if cs.size != 1
      @start = cs[0]
    end
  end
  
  def files_to_compile
    cs
  end
  
  def include_dirs
    hs.map {|h| h.dirname }.uniq
  end
  
  def cs
    files.select {|s| s.c? }
  end
  
  def hs
    files.select {|s| s.h? }
  end
  
  def files
    @files ||= @start.all_related_sources
  end
end

end # module Mukumufu

if __FILE__ == $0
  if !ARGV.delete('--test')
    require 'erb'
    require 'optparse'
    
    Version = 'v2'
    
    class Mukumufu::Main
      def self.main(*args)
        new(*args).main
      end
      
      def initialize(erb_template_line)
        dir = 'src'
        start = 'main'
        graph = false
        raw_graph = false
        out = nil
        default_out = 'Makefile.inc.txt'
        ignore_head = []
        
        ARGV.options do |o|
          o.on('-d', '--srcdir=DIR', "root src directory (default: #{dir.inspect})") {|a| dir = a }
          o.on('-s', '--start=START', "file to be scanned first (defaults to #{start.inspect})") {|a| start = a }
          o.on('-o', '--out=FILENAME', "output (default: #{default_out.inspect})") {|a| out = a }
          o.on('-g', '--graph', "generate a DOT file (default output set to '-' if specified)") {|a| graph = a }
          o.on('-r', '--raw-graph', "show #include dependency when generating a graph (implies --graph)") {|a| raw_graph = a; graph = true }
          o.on('-i', '--ignore-head=NAME', "ignore references to the file when generating a graph") {|a| ignore_head << a }
          
          o.on_tail("-h", "--help", "show this message") do
            puts o
            exit
          end
          
          o.on_tail('--test', 'run tests') {}
          
          o.parse!
        end
        
        @erb_template_line = erb_template_line
        @dir = dir
        @start = start
        @out = out || (graph ? '-' : default_out)
        @graph = graph
        @raw_graph = raw_graph
        @ignore_head = ignore_head
      end
      
      def main
        @tree = Mukumufu::SourceTree.new(@dir, @start)
        
        if @out == '-'
          @io = STDOUT
          run
        else
          open(@out, 'w') do |f|
            @io = f
            run
          end
        end
      end
      
      private
      def run
        if @graph
          generate_graph
        else
          generate_makefile
        end
      end
      
      def generate_makefile
        tree = @tree
        objs = {}
        
        tree.files_to_compile.each do |c|
          objs[c] = "$(OBJDIR)/#{c.name}.$(O)"
        end
        
        result = eval(ERB.new(DATA.read, nil, '%').src, binding, __FILE__, @erb_template_line)
        
        @io.print(result)
      end
      
      def generate_graph
        @io.puts "// Try the 'tred' tool in the Graphviz to get a less cluttered result"
        @io.puts "// example: mukumufu.rb --graph | tred | dot -Tgif -odeps.gif"
        @io.puts 'digraph {'
        @io.puts '  overlap = false;'
        @io.puts '  rankdir = LR;'
        @io.puts '  node [style = filled, fontcolor = "#123456", fillcolor = white, fontsize = 30, fontname="Arial, Helvetica"];'
        @io.puts '  edge [color = "#661122"];'
        @io.puts 'bgcolor = "transparent";'
        
        sources, headers, links = collect_nodes_for_graph
        
        @io.puts ''
        
        @io.puts '// sources'
        sources.each do |s|
          @io.puts %{  "#{s}" [label = "#{s}", shape = box];}
        end
        
        @io.puts ''
        @io.puts '// headers'
        
        (headers - sources).each do |s|
          @io.puts %{  "#{s}" [label = "#{s}", shape = ellipse];}
        end
        
        links.each do |link|
          @io.puts link
        end

        @io.puts '}'
      end
      
      def collect_nodes_for_graph
        sources = Set.new
        headers = Set.new
        links = Set.new
        
        if @raw_graph
          get_name = :basename
          each = :each_depending_header
        else
          get_name = :name
          each = :each_neighbor
        end
        
        @tree.files.each do |s|
          name = s.__send__(get_name)
          (s.c? ? sources : headers) << name
        
          s.__send__(each) do |t|
            tname = t.__send__(get_name)
            next if name == tname || @ignore_head.include?(tname)
            links << %[  "#{name}" -> "#{tname}";]
          end
        end
        
        headers.subtract(sources)
        
        return sources, headers, links
      end
    end
    
    # main is called at the end of this big else clause
  else # test
    require 'rubygems'
    require 'shoulda'
    
    begin
      require 'redgreen'
      require 'win32console'
    rescue LoadError
    end
    
    include Mukumufu
    
    module Taiyaki
      def setup_taiyaki(list)
        @komugikoh = make_header(list, 'komugiko')
        @kawah, @kawac = @kawapair = make_pair(list, 'kawa', 'komugiko')
        @azukih, @azukic = @azukipair = make_pair(list, 'azuki')
        @ankoh, @ankoc = @ankopair = make_pair(list, 'anko', 'azuki')
        @taiyakih, @taiyakic = @taiyakipair = make_pair_sparse(list, 'taiyaki', 'kawa', 'anko')
        @cs = [@kawac, @azukic, @ankoc, @taiyakic]
        @hs = [@kawah, @azukih, @ankoh, @taiyakih, @komugikoh]
        @all = @cs + @hs
      end
      
      def taiyaki_check_deps
        assert_same_elements [], @taiyakih.depending_header_names
        assert_same_elements [@azukih.basename], @ankoh.depending_header_names
        assert_same_elements [@komugikoh.basename], @kawah.depending_header_names
        assert_same_elements [], @azukih.depending_header_names
        assert_same_elements [], @komugikoh.depending_header_names
        
        @cs.each do |e|
          if e.equal?(@taiyakic)
            hs = [@kawah.basename, @ankoh.basename, @taiyakih.basename]
          else
            hs = ["#{e.name}.h"]
          end
          assert_same_elements hs, e.depending_header_names
        end
      end
      
      private
      def make_header(list, n, *deps)
        base = "#{n}.h"
        path = "#{tree}#{base}"
        body = make_inc(*deps)
        h = Source.new(list, path, body)
        
        list.add h unless list.nil?
        
        assert_equal normalize_path(path), h.path
        assert_equal base, h.basename
        assert_equal n, h.name
        assert_equal true, h.h?
        assert_equal false, h.c?
        assert_equal body, h.content
        
        h
      end
      
      def make_source(list, n, *deps)
        exts = %w/cpp cc c/
        ext = exts[rand(exts.size)]
        base = "#{n}.#{ext}"
        path = "#{tree}#{base}"
        body = make_inc(n, *deps)
        c = Source.new(list, path, body)
        
        assert_equal normalize_path(path), c.path
        assert_equal base, c.basename
        assert_equal n, c.name
        assert_equal false, c.h?
        assert_equal true, c.c?
        assert_equal body, c.content
        
        list.add c unless list.nil?
        
        c
      end
      
      def normalize_path(path)
        path.gsub(/[\/\\]+/, '/')
      end
      
      def make_pair(list, n, *deps)
        return make_header(list, n, *deps), make_source(list, n)
      end
      
      def make_pair_sparse(list, n, *deps)
        return make_header(list, n), make_source(list, n, *deps)
      end
      
      def tree
        if rand(3) == 0
          dirs = ['hoge', 'fuga', '', '.']
          Array.new(rand(4)) { dirs[rand(dirs.size)] }.join('/') + '/'
        end
      end
      
      def make_inc(*deps)
        parens = %w/<> ""/
        open, close = parens[rand(parens.size)].split(//)
        deps.map {|d| "##{spc}#{incl}#{spc}#{open}#{d}.h#{close}" }.join("\n")
      end
      
      def spc
        spaces = [' ', "\t"]
        Array.new(rand(5)) { spaces[rand(spaces.size)] }.join
      end
      
      def incl
        k = 'include'
        shuffle_case k
        k
      end
      
      private
      def shuffle_case(str)
        rand(str.size).times do
          i = rand(str.size)
          str[i] = str[i, 1].upcase
        end
      end
    end

    class SourceTest < Test::Unit::TestCase
      include Taiyaki
      
      context 'a' do
        context 'filename' do
          setup do
            @m = Source.new(nil, 'hoge/fuga/moga.cpp')
            @b = Source.new(nil, 'foo/bar/baz.c')
            @f = Source.new(nil, 'fred.h')
            @c = Source.new(nil, 'cat.jpg')
            @all = [@m, @b, @f, @c]
          end
          
          should 'path' do
            assert_equal 'hoge/fuga/moga.cpp', @m.path
            assert_equal 'foo/bar/baz.c', @b.path
            assert_equal 'fred.h', @f.path
            assert_equal 'cat.jpg', @c.path
          end
          
          should 'name' do
            assert_equal 'moga', @m.name
            assert_equal 'baz', @b.name
            assert_equal 'fred', @f.name
            assert_equal 'cat', @c.name
          end
          
          should 'tree' do
            assert_equal 'hoge/fuga', @m.tree
            assert_equal 'foo/bar', @b.tree
            assert_equal '.', @f.tree
            assert_equal '.', @c.tree
          end
          
          should 'basename' do
            assert_equal 'moga.cpp', @m.basename
            assert_equal 'baz.c', @b.basename
            assert_equal 'fred.h', @f.basename
            assert_equal 'cat.jpg', @c.basename
          end
          
          should 'basename+tree' do
            @all.each do |s|
              if s.tree == '.'
                assert_equal s.path, s.basename
              end
            end
          end
          
          should 'extname' do
            assert_equal 'cpp', @m.extension
            assert_equal 'c', @b.extension
            assert_equal 'h', @f.extension
            assert_equal 'jpg', @c.extension
          end
          
          should 'type' do
            assert_equal true, @m.c?
            assert_equal false, @m.h?
            
            assert_equal true, @b.c?
            assert_equal false, @b.h?

            assert_equal false, @f.c?
            assert_equal true, @f.h?

            assert_equal false, @c.c?
            assert_equal false, @c.h?
          end
        end
      end
      
      context 'many' do
        context 'deps alone' do
          setup do
            setup_taiyaki(nil)
          end
          
          should 'detect #include' do
            taiyaki_check_deps
          end
        end
      end
    end
    
    class SourceListTest < Test::Unit::TestCase
      context 'alone' do
        setup do
          @e0 = SourceList.new
          @e1 = SourceList.new('hoge.h')
          @e2 = SourceList.new('hoge.h', 'hoge.c')
          @all = [@e0, @e1, @e2]
        end
        
        should 'empty?' do
          assert_equal true, @e0.empty?
          assert_equal false, @e1.empty?
          assert_equal false, @e2.empty?
        end

        should 'size' do
          assert_equal 0, @e0.size
          assert_equal 1, @e1.size
          assert_equal 2, @e2.size
        end
        
        should 'index nonexistent' do
          assert_nil @e0['foo.c']
          assert_nil @e1['bar.c']
          assert_nil @e2['baz.c']
        end
        
        should 'find_source' do
          assert_nil @e1['hoge.h'].find_source
          assert_same @e2['hoge.c'], @e2['hoge.h'].find_source
          assert_raise(ArgumentError) { @e2['hoge.c'].find_source }
        end
      end
    end

    class SourceListWithSourceTest < Test::Unit::TestCase
      include Taiyaki
      
      context 'source-list' do
        setup do
          @list = SourceList.new
          setup_taiyaki @list
        end
        
        should 'elems' do
          assert_same_elements @all, @list
        end
        
        should 'deps' do
          taiyaki_check_deps
        end
        
        should 'index' do
          assert_nil @list['foo.c']
          
          @all.each do |s|
            assert_same s, @list[s.path]
            assert_same s, @list[s.basename]
          end
        end
        
        should 'depending_headers' do
          assert_same_elements [@taiyakih, @kawah, @ankoh], @taiyakic.depending_headers
          assert_same_elements [@ankoh], @ankoc.depending_headers
          assert_same_elements [@kawah], @kawac.depending_headers
          assert_same_elements [@azukih], @azukic.depending_headers
          
          assert_same_elements [], @taiyakih.depending_headers
          assert_same_elements [@azukih], @ankoh.depending_headers
          assert_same_elements [@komugikoh], @kawah.depending_headers
          assert_same_elements [], @azukih.depending_headers
          assert_same_elements [], @komugikoh.depending_headers
        end
        
        should 'all_related_sources' do
          assert_same_elements @all, @taiyakic.all_related_sources
          assert_same_elements [@ankoc, @azukic, @ankoh, @azukih], @ankoc.all_related_sources
          assert_same_elements [@kawac, @kawah, @komugikoh], @kawac.all_related_sources
          assert_same_elements [@azukic, @azukih], @azukic.all_related_sources
          
          assert_same_elements [@taiyakih], @taiyakih.all_related_sources
          assert_same_elements [@ankoh, @azukih, @azukic], @ankoh.all_related_sources
          assert_same_elements [@kawah, @komugikoh], @kawah.all_related_sources
          assert_same_elements [@azukih], @azukih.all_related_sources
          assert_same_elements [@komugikoh], @komugikoh.all_related_sources
        end
        
        should 'find_source' do
          assert_same @taiyakic, @taiyakih.find_source
          assert_same @ankoc, @ankoh.find_source
          assert_same @kawac, @kawah.find_source
          assert_same @azukic, @azukih.find_source
          assert_nil @komugikoh.find_source
          
          @cs.each {|s| assert_raise(ArgumentError) { s.find_source } }
        end
      end
    end
    
    class SourceTreeTest < Test::Unit::TestCase
      include Taiyaki
      
      context 'source-tree' do
        setup do
          @list = SourceList.new
          setup_taiyaki @list
        end
        
        should 'deps' do
          taiyaki_check_deps
        end
        
        should 'files_to_compile' do
          test_files_to_compile @cs, 'taiyaki'
          test_files_to_compile [@ankoc, @azukic], 'anko'
          test_files_to_compile [@kawac], 'kawa'
          test_files_to_compile [@azukic], 'azuki'
        end
      end
      
      def test_files_to_compile(cs, start)
        tree = SourceTree.new(@list, start)
        assert_same_elements cs, tree.files_to_compile
      end
    end
  end

  Mukumufu::Main.main(__LINE__ + 5) if defined? Mukumufu::Main
end

# erb template below
__END__
## This file is generated by mukumufu.rb v2
#
## Include this file in your Makefile like:
#   Makefile.inc.txt:
#       ruby mukumufu.rb
#   include Makefile.inc.txt
#
## Required variables:
#   OBJDIR
#   O
#   CC_OBJ_OUT_FLAG (-Fo in MSVC, -o in GCC)
#
## Customizable variables:
#   CC
#   CXX
#   CFLAGS
#   CXXFLAGS
#
## Variables defined in this file:
#   OBJS
#   CFLAGS_INCLUDE_DIRS
#
## example for MSVC:
#   O = obj
#   CC_OBJ_OUT_FLAG = -Fo
#   OBJDIR = obj~
#   $(OBJS): $(OBJDIR)
#   $(OBJDIR):
#   	mkdir $(OBJDIR)
#
# example for GCC:
#   O = o
#   CC_OBJ_OUT_FLAG = -o
#   OBJDIR = obj~
#   $(OBJS): $(OBJDIR)
#   $(OBJDIR):
#   	mkdir $(OBJDIR)

OBJS = \
<%= objs.map {|c,obj| "  #{obj}" }.sort.join(" \\\n") %>

CFLAGS_INCLUDE_DIRS = \
<%= tree.include_dirs.sort.map {|dir| "  -I#{dir}" }.sort.join(" \\\n") %>

# header-header deps

% tree.hs.sort_by {|h| h.path }.each do |h|
%   ds = h.depending_headers
%   next if ds.empty?
<%=  h %>: <%= ds.map {|d| d.path }.sort.join(' ') %>
% end

# source-header deps

% tree.cs.sort_by {|c| c.path }.each do |c|
%   ds = c.depending_headers
%   next if ds.empty?
<%=  c %>: <%= ds.map {|d| d.path }.sort.join(' ') %>
% end

# object-source deps

% objs.sort_by {|c,obj| obj }.each do |c,obj|
<%= obj %>: <%= c %>
	<%= c.cxx? ? '$(CXX) $(CXXFLAGS)' : '$(CC) $(CFLAGS)' %> $(CFLAGS_INCLUDE_DIRS) $(CC_OBJ_OUT_FLAG)<%= obj %> -c <%= c %>

% end
