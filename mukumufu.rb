# generates Makefile.inc.txt

require 'set'
require 'enumerator'
require 'kconv'

module Enumerable
  def dfs(visited = Set.new, &blk)
    return if visited.include?(self)
    
    blk.call self
    visited << self
    
    each {|x| x.dfs(visited, &blk) }
  end
end

class Mukumufu
  attr_reader :objs, :includes, :source_header_dependencies, :object_source_dependencies, :header_header_dependencies
  
  def write(f = STDOUT)
    calculate unless @calculated
    
    f.puts objs
    f.puts
    f.puts header_header_dependencies
    f.puts
    f.puts source_header_dependencies
    f.puts
    f.puts object_source_dependencies
  end
  
  def calculate
    sources = Sources.new(Dir['src/**/*.{c,h,cpp,hpp}'])
    
    includes = sources.header_dirs
    
    hhdeps = {}
    shdeps = {}
    osdeps = {}
    
    main = sources['main.c']
    all = main.all_related_sources
    
    all.each do |source|
      if source.header?
        h = source
        hhdeps[h.path] = h.depending_headers
      else
        c = source
        osdeps[obj_path(c.name)] = [c]
        shdeps[c] = c.depending_headers
      end
    end
    
    objs = osdeps.keys
    
    @objs = file_list('OBJS', objs, %_ \\\n  _)
    @header_header_dependencies = dep_list(hhdeps)
    @source_header_dependencies = dep_list(shdeps)
    @object_source_dependencies = dep_list(osdeps, compile_command(includes))
    @calculated = true
    self
  end
  
  private
  def obj_path(name)
    "$(OBJDIR)/#{name.gsub(/\.c\z/, '.$(O)')}"
  end
  
  def file_list(name, list, separator)
    str = (["#{name} ="] + list.sort).join(separator)
    str
  end
  
  def dep_list(hash, command=nil)
    command &&= "\n\t#{command}\n"
    
    str = hash.
      reject {|k,v| v.empty? }.
      map {|c,h| "#{c}: #{h.map {|x| x.to_s }.sort.join(' ')}#{command}" }.
      sort.
      join("\n")
    str
  end
  
  def compile_command(includes)
    inc = includes.map {|x| "-I#{x}" }.join(" ")
    o = "$(CC_OBJ_OUT_FLAG)$@ -c $?"
    "$(CC) $(CFLAGS) #{inc} #{o}"
  end
end

class Sources
  include Enumerable
  
  def initialize(files)
    @sources = files.map {|f| Source.new(self, f) }
  end
  
  def header_dirs
    @header_dirs ||= make_header_dirs
  end
  
  def [](name)
    @index_cache ||= {}
    @index_cache[name] ||= find_file(name)
  end
  
  def each(&blk)
    @sources.each(&blk)
  end
  
  private
  def make_header_dirs
    @sources.map {|s| s.dir if s.header? }.compact.sort.uniq
  end
  
  def find_file(str)
    files = @sources.select {|s| s.path == str || s.name == str }
    
    case files.size
    when 1
      files[0]
    when 0
      nil
    else
      raise FileNameConflictError, "file name conflict: #{files.map {|x| x.path }.inspect}"
    end
  end
  
  class FileNameConflictError < StandardError
  end
end

class Source
  attr_reader :path
  
  include Enumerable
  
  def initialize(sources, path)
    @sources = sources
    @path = path
  end
  
  alias to_s path
  
  def name
    @name ||= File.basename(path)
  end
  
  def ext
    @ext ||= File.extname(path)
  end
  
  def dir
    @dir ||= File.dirname(path)
  end
  
  def header?
    ext == '.h' || ext == '.hpp'
  end
  
  def each(&blk)
    depending_headers.each(&blk)
    depending_sources.each(&blk)
  end
  
  def all_related_sources
    enum_for(:dfs).to_set
  end
  
  def depending_headers
    @depending_headers ||= make_depending_headers
  end
  
  def depending_sources
    @depending_sources ||= make_depending_sources
  end
  
  private
  def make_depending_headers
    headers = IO.read(path).toutf8.scan(/^#\s*include\s*"([^"]*)"$/i)
    headers.map {|header_name| @sources[header_name[0]] }.compact
  end
  
  def make_depending_sources
    depending_headers.map {|h| find_source(h) }.compact
  end
  
  def find_source(h)
    c = h_to_c(h)
    cpp = h_to_cpp(h)
    
    if c && cpp
      raise "both c and cpp exists for header \"#{h.path}\""
    end
    
    c || cpp
  end
  
  def h_to_c(h)
    @sources[h.path.gsub(h.ext, '.c')]
  end
  
  def h_to_cpp(h)
    @sources[h.path.gsub(h.ext, '.cpp')]
  end
end

def main
  m = Mukumufu.new
  m.calculate
  
  if ARGV.include?('-n')
    m.write
  else
    open('Makefile.inc.txt', 'w') {|f| m.write f }
  end
end

main if __FILE__ == $0
