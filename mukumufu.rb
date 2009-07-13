# generates Makefile.inc.txt for nmake

class Mukumufu
  def make
    @libs = make_libs
    @deptable = make_deptable
    @cs = make_cs
    @objs = make_objs
    
    template
  end

  private

  attr_reader :cs, :libs, :deptable, :objs
  

  # calculation
  
  def make_libs
    Dir['lib/*.lib']
  end
  
  def make_cs
    # calculate fixpoint of deptable
    
    deptable['main.c']
    old_size = 1
    cs = nil
    
    while true
      cs = make_current_cs
      old_size = deptable.size
      cs.each {|c| deptable[c] }
      break if old_size == deptable.size
    end
    
    cs.sort.uniq
  end
  
  def make_current_cs
    deptable.
      values.
      flatten.
      map {|h| deptable[h]; h.gsub(/\.h\z/, '.c') }.
      select {|c| File.exist? src(c) }.
      unshift('main.c')
  end

  def make_objs
    cs.map {|c| "$(OBJDIR)/#{c.gsub(/c\z/, '$(O)')}" }
  end
  
  def src(x)
    "src/#{x}"
  end
  
  def grep_headers(filename)
    IO.read(src(filename)).
      scan(/^#\s*include\s*"([^"]*)"$/).
      select {|x| File.exist? src(x) }.flatten
  end
  
  def make_deptable
    Hash.new {|h,k| h[k] = grep_headers(k) }
  end
  
  # stringification
  
  def dirlist(list)
    str = list.join(%_ \\\n  _)
    str.gsub!('/', '\\') if windows?
    str
  end
  
  def windows?
    RUBY_PLATFORM =~ /mswin(?!ce)|mingw|cygwin|bccwin/
  end
  
  def header_dependency
    deptable.
      reject {|k,v| v.empty? }.
      map {|c,h| "#{c}: #{h.join(' ')}" }.
      join("\n")
  end
  
  def template
    <<-EOS
OBJS = \\
  #{dirlist(objs)}

LIBS = \\
  #{dirlist(libs)}

#{header_dependency}
    EOS
  end
end


def main
  text = Mukumufu.new.make
  
  open('Makefile.inc.txt', 'w') do |f|
    f << text
  end
end

main if __FILE__ == $0
