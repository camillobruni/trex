# == Synopsis
#   trex is script simplifying the compilation of latex files by creating
#   proper human-readable error output with repeating patterns. Unlike the
#   original latex output which is oververbosified.
#
# == Examples
#   ./trex view     # compiles and opens the pdf, equivalent to just ./trex
#   ./trex clean    # removes all generated files
#   ./trex tex      # compiles the latex sources
#   ./trex count    # gives different word approximations of the latex file
#   ./trex check    # run afterthedeadline / latex checker on the document
#
# == Usage
#   trex [options] [view|compile|tex|clean|check|count]
#   For help use: trex -h
#
# == Options
#   -h, --help          Displays help message
#   -v, --version       Display the version, then exit
#   -q, --quiet         Output as little as possible, overrides verbose
#   -V, --verbose       Output lists all errors, overrides quiet
#   --figures           Set the figures dir, default is './figures'
#   --hack              Open this script for direct changes in the sources
#
# == Authors
#   Camillo Bruni, Toon Verwaest, Damien Pollet
#

# ============================================================================
# CHANGE THESE PROPERTIES FOR YOUR PROJECT
SOURCE  = nil
FIGURES = 'figures'    # not yet used
GARBAGE = 'log aux out blg pdfsync synctex.gz'

# ============================================================================

require 'optparse'
require 'ostruct'
require 'date'
require 'logger'
require 'open3'
require 'term/ansicolor'

class String
    include Term::ANSIColor
    
    def error(exitValue=nil)
        puts self.red.bold
        exit exitValue unless exitValue.nil?
    end
end

def color_terminal?
    return true if STDOUT.isatty
    [/linux/, /xterm.*/, /rxvt.*/].each { |m|
        return true if ENV['TERM'] =~ m
    }
    return false
end

Term::ANSIColor::coloring = color_terminal?

#require 'ruby-debug19'
#Debugger.start(:post_mortem => true)
# Debugger.start()

# ============================================================================
#TODO track changed files and only recompile then...
class TReX
    VERSION = '1.0.8'

    attr_reader :options

    # mapping of input command shortcuts and method names
    VALID_ACTIONS = {
        "view" =>    :view,
        "compile" => :compile,
        "tex" =>     :compile,
        "count" =>   :count,
        "clean" =>   :clean,
        "bibtex" =>  :bibtex,
        "bib" =>     :bibtex,
        "v" =>       :view,
        "spell" =>   :spell_check,
        "check" =>   :spell_check,
    }

    # ------------------------------------------------------------------------
    def initialize(arguments, stdin)
        @arguments           = arguments
        @stdin               = stdin
        @action              = :compile
        @opts                = nil
        # Set defaults
        @options             = OpenStruct.new
        @options.verbose     = false
        @options.quiet       = false
        @options.interaction = 'nonstopmode'
        @options.garbage     = GARBAGE
        @options.figures     = FIGURES
    end

    # ------------------------------------------------------------------------
    def source!(sourceFile)
        @options.source      = sourceFile
        @options.sourceBase  = sourceFile.sub(/\.\w+$/,'')
        @options.output      = @options.sourceBase + '.pdf'
    end


    # ------------------------------------------------------------------------
    def check_source
        return if File.exist?(@options.source)
        if not @options.source.end_with? "tex"
            @options.source += '.' if not @options.source.end_with? '.'
            @options.source += 'tex'
            self.source! @options.source
        end
        return if File.exist?(@options.source)
        print "File doesn't exist: ".red.bold, @options.source, "\n"
        exit 1
    end

    # ------------------------------------------------------------------------
    def run
        begin
            if self.parsed_options? && self.arguments_valid?
                self.process_arguments
                self.process_command
            else
                self.output_usage
            end
        rescue Interrupt
            puts ''
        end
    end

    # ------------------------------------------------------------------------
    def hack
        editor = ENV['EDITOR'] || "vim"
        cmd = "sudo #{editor} #{__FILE__}"
        print cmd
        exec(cmd)
    end

    # ------------------------------------------------------------------------
    def clean
        @options.garbage.split.each { |f|
            `rm -f #{@options.sourceBase}.#{f}`
        }
    end

    # ------------------------------------------------------------------------
    def compile
        self.check_commands
        self.check_source
        baseCommand = self.create_compile_baseCommand
        # 1/4 first run interactive... ignoring cite/ref errors
        formatter = TexOutputFormatter.new(`#{baseCommand}`,
                                           @options.verbose, @options.quiet,
                                           @options.source)
        if not formatter.hasCitationWarnings? \
           and not formatter.hasReferenceWarnings?
            formatter.print unless @options.quiet
            return true
        end
        # 2/4 bibtex on citation warnings
        if formatter.hasCitationWarnings? and not self.bibtex \
           and not @options.quiet
            # obviously something went wrong in either compiling bibtex or the
            # latex file itself. Print everything except for reference and
            # citation warnings
            errorGroups = formatter.errorGroups
            errorGroups.delete formatter.referenceWarnings
            errorGroups.delete formatter.citationWarnings
            formatter.print
        end
        # 3/4 second run
        if not system("#{baseCommand} > /dev/null 2>&1")
            formatter.print
            "\n! Could not create PDF !".error
            return false
        end
        # 4/4 looking for ref/cite errors
        formatter = TexOutputFormatter.new(`#{baseCommand}`,
                                           @options.verbose, @options.quiet,
                                           @options.source)
        formatter.print if not @options.quiet
        return true
    end

    # ------------------------------------------------------------------------
    def bibtex
        if not File.exist?(@options.sourceBase + '.aux')
            return self.compile
        end
        warning = BibtexWarning.new()
        warning.handle(`bibtex #{@options.sourceBase + '.aux'}`)
        puts warning.to_s unless warning.empty?
        return warning.empty?
    end

    # ------------------------------------------------------------------------
    def view
        self.compile
        open = nil
        if RUBY_PLATFORM.include? "linux"
            'gnome-open evince kpdf Xpdf'.split.each { |c|
                if self.has_command? c
                    open = c
                    break
                end
            }
        elsif RUBY_PLATFORM.include? "darwin"
            open = 'open'
        end
        if open.nil?
            "\n no command found to open #{ @options.output} !\n".error 1
        end
        system("#{open} #{@options.output}")
    end

    # ------------------------------------------------------------------------
    def count
        @options.quiet = true
        self.count_wc
        self.count_texcount
        self.compile
        self.count_pdf_info
        self.count_pdf_to_text
    end

    def count_wc
      puts "Source:".red + " #{@options.source}:"
      self.print_wc_results `wc #{@options.source}`
    end

    def count_pdf_info
      rutn unless self.has_command? 'pdfinfo'
      puts 'PDFInfo'.red + ":"
      puts `pdfinfo #{@options.output}`
    end

    def count_pdf_to_text
      return unless self.has_command? 'pdftotext'
      puts 'PDFtoText'.red + ":"
      #TODO create a tmp file instead of saving locally
      self.print_wc_results `pdftotext -enc UTF-8 -nopgbrk #{@options.output} - | wc`
      `rm -f #{@options.sourceBase}.txt`

    end

    def count_texcount
        return unless self.has_command? 'texcount'
        puts 'texcount'.red + ":"
        puts `texcount -relaxed -sum -inc -merge -col -sub=chapter #{@options.source} 2> /dev/null`
    end


    def print_wc_results(result)
        result = result.split()[0..2]
        max    = result.map{|l| l.size}.max
        puts "    #{result[0].rjust(max).yellow} lines"
        puts "    #{result[1].rjust(max).yellow} words"
        puts "    #{result[2].rjust(max).yellow} characters"

    end

    # ------------------------------------------------------------------------
    def spell_check
        require 'tempfile'
        self.check_source 

        detexed = Tempfile.new(@options.source)
        # strip away spell warnings occuring before the \begin{document}
        documentStartLine = self.detect_document_start_line
        # strip all the latex commands using detex
        `tail -n +#{documentStartLine} #{@options.source} | detex -e stcode,ccode,listing > #{detexed.path}`

        # run the spellchecker
        output = `atdtool #{detexed.path}`
        output = output.gsub(detexed.path, File.basename(@options.source))
        
        detexed.unlink
        output.lines do |line|
            if line.match(/^  /)
                print ' '
                print line.strip
            else
                /(?<file>[^:]+)\:(?<line>\d+)\:(?<col>\d+)\:(?<rest>[^"]+)(?<match> "[^"]+")(?<trailing>.*)/ =~ line
                print "\n"
                print file 
                print ':'
                print line.to_i + documentStartLine - 1
                print ':'
                print col
                print ':'
                print match
                print rest
                print trailing.strip
            end
        end
        puts ''
    end
    
    # ------------------------------------------------------------------------
    protected
  
        def detect_document_start_line
            lineNumber = 0
            File.open(@options.source) do |f|
                f.each_line do |line|
                    return lineNumber if line.match(/^\\begin{document}/)
                    lineNumber += 1
                end
            end
        end

        # Specify options
        def option_parser
            return @opts unless @opts.nil?

            @opts = OptionParser.new do |opts|
                opts.banner = "#{executable_name} [options] [view|compile|tex|clean|spell|count]"

                opts.separator ''
                opts.separator 'Automate compilation of LaTeX documents, making the output human-readable.'
                opts.separator ''

                opts.on '--figures PATH', "Set the figures directory (default #{FIGURES})" do |path|
                    @options.figures = path
                end
                opts.on '-V', '--verbose', 'List all errors (overrides --quiet)' do
                    @options.verbose = true
                end
                opts.on '-q', '--quiet', 'Output as little as possible (overrides --verbose)' do
                    @options.quiet = true
                end

                opts.separator ''
                opts.on '-h', '--help', 'Display this help message' do
                    self.output_help
                    exit 0
                end
                opts.on '-v', '--version', 'Show version' do
                    self.output_version
                    exit 0
                end
                opts.on '--hack', 'Open this script for direct changes in the sources' do
                    self.hack
                end
            end
        end

        def parsed_options?
            option_parser.parse!(@arguments) rescue return false
            self.process_options
            true
        end

        # Performs post-parse processing on options
        def process_options
            @options.verbose = false if @options.quiet
        end

        # True if required arguments were provided
        def arguments_valid?
            return false if not @action and not VALID_ACTIONS.keys.include? @arguments[0]
            true
        end

        # Setup the arguments
        def process_arguments
            if not @action or VALID_ACTIONS.keys.include? @arguments[0]
                @action = VALID_ACTIONS[@arguments.shift]
            end
            if not @arguments.empty?
                self.source! @arguments.shift
            elsif not SOURCE.nil?
                self.source! SOURCE
            end
            if @options.source.nil?
                self.extract_source_from_current_dir
            end
            'Source file not set!'.error 1 if @options.source.nil?
        end

        # ---------------------------------------------------------------------

        def executable_name
            File.basename(__FILE__)
        end

        def output_help
            self.output_version
            output_usage
        end

        def output_usage
            puts @opts.help
        end

        def output_version
            puts "#{executable_name} version #{VERSION}"
        end

        # ---------------------------------------------------------------------
        def extract_source_from_current_dir
            texFiles = Dir['*.tex']
            texFiles = texFiles.select { |file|
                File.read(file).match(/\\documentclass.*?\{.*?\}/)
            }
            return if texFiles.empty?
            return self.source! texFiles.first if texFiles.length == 1
            self.source! self.promptChoice texFiles
        end

        def promptChoice(args)
            args.sort!
            for i in 1..args.length
                puts "[#{i}] #{args[i-1]}"
            end
            choice = nil
            while choice.nil?
                print "Which is the source file?[number]: "
                choice = args[gets.chomp.to_i-1]
            end
            return choice
        end

        def check_commands
            missing = []
            'pdflatex bibtex'.split.each { |c|
                missing.push(c) unless self.has_command? c
            }
            if not missing.empty?
                print 'Missing commands for running the script: '.red.bold
                puts missing.join(', ')
                if RUBY_PLATFORM.include? "linux"
                    puts 'install latex with your favorite package manager'
                elsif RUBY_PLATFORM.include? "darwin"
                    puts 'install the latest latex from http://www.tug.org/mactex'
                end
            end
        end

        def process_command
            self.send @action
        end

        # ---------------------------------------------------------------------
        def has_command?(command)
            # disable warnings during the script checking, so we get only
            # errors in stderr. Warnings can cause problems during the
            # detection, for example ( warning: Insecure world writable dir
            # /some/path in PATH, mode 040777 )
            @warn = $-v
            $-v   = nil
            result = system('type #{command} >/dev/null 2>&1')
            $-v   = @warn
            return result
        end

        # ---------------------------------------------------------------------
        def create_compile_baseCommand
            "pdflatex -synctex=1 --interaction #{@options.interaction} '#{@options.source}'"
        end

end

# ============================================================================

class TexOutputFormatter
    attr_reader :errorGroups, :citationWarnings, :referenceWarnings
    attr_writer :errorGroups

    def initialize(texOutput, verbose=false, quiet=false,  source=nil,
                  errorGroups=nil)
        #TODO add arg check
        @texOutput     = texOutput
        @source        = source
        @totalWarnings = 0
        @parsed        = false
        @verbose       = verbose
        @quiet         = quiet
        @errorGroups   = errorGroups
        self.initialize_error_groups
    end

    def initialize_error_groups
        interestingLimits   = 50
        interestingLimits   = 0 if @quiet
        uninterestingLimits = 0
        uninterestingLimits = 50 if @verbose
        return unless @errorGroups.nil?

        @filestate         = FilenameParser.new
        @citationWarnings  = CitationWarning.new(interestingLimits)
        @referenceWarnings = ReferenceWarning.new(interestingLimits)
        @errorGroups = [
          PDFVersionMismatchWarning.new(uninterestingLimits),

          TexWarning.new('Underfull lines',
                         /Underfull.*/,
                         /\(badness [0-9]+\) in \w+/,
                         uninterestingLimits),

          TexWarning.new('Overfull lines',
                         /Overfull.*/,
                         /\w+ \(.*?\) in \w+/,
                         uninterestingLimits),

          TexWarning.new('Float changes',
                         /Warning:.*?float specifier changed to/,
                         /float specifier .*/,
                         uninterestingLimits),

          TexWarning.new('Package Warning',
                         /Package .* Warning/,
                         /.*/,
                         uninterestingLimits),


          FontWarning.new(uninterestingLimits),

          @citationWarnings, @referenceWarnings,

          TooManyWarning.new(interestingLimits),

          RepeatedPageNumberWarning.new(uninterestingLimits),

          TexError.new('Undefined Control Sequence',
                        /! Undefined control /,
                        /\\.*/, interestingLimits),

          TexError.new('LaTeX error', /! LaTeX Error/, /.*/,
                        interestingLimits),

          MissingParenthesisWarning.new(@source, interestingLimits),

          PharagraphEndedWarning.new(@source, interestingLimits),

          TexWarning.new('File not Found',
                         /Warning: File/,
                         /[^ ]+ not found/,
                         interestingLimits),

          MultipleLabelWarning.new(@source, interestingLimits),

          TexError.new('Other Errors', /^! /, /.*/, interestingLimits),

          @filestate,

          OtherWarning.new,
        ]
        @errorGroups.each { |eg| eg.filestate = @filestate }
    end

    # ------------------------------------------------------------------------
    def hasCitationWarnings?
        self.parse unless @parsed
        not @citationWarnings.empty?
    end

    def hasReferenceWarnings?
        self.parse unless @parsed
        not @referenceWarnings.empty?
    end

    # ------------------------------------------------------------------------

    def add(handler)
        handler.filestate = @filestate
        @errorGroups.push handler
    end

    def print
        self.parse unless @parsed
        @errorGroups.each { |group|
            if not group.empty?
                 Kernel.print group.to_s
            end
        }
    end

    # ------------------------------------------------------------------------
    protected
        def parse
            lineNumberPattern = /lines ([0-9\-]+)/
            @parsed           = true
            mergedLine        = ""
            lines             = @texOutput.split "\n"
            lines.each_with_index { |line,index|
                #magic to unwrap the autowrapped lines from latex.. silly
                mergedLine += line
                if line.size == 79
                    next
                elsif line.chomp.start_with? "! Undefined"
                    next
                end
                # start of the actual error parsing
                line    = mergedLine
                handled = false
                @errorGroups.each { |group|
                    break if group.handle(line, index, lines)
                }
                #Kernel.print line, "\n"
                #Kernel.print line, "\n" if not handled
                mergedLine = ""
            }
        end
end

# ============================================================================
class TexWarning
    attr_reader :limit
    attr_accessor :filestate

    def initialize(name, pattern, printPattern=/.*/, limit=10,
                   additionaInputLines=0)
        @name                     = name
        @pattern                  = pattern
        @printPattern             = printPattern
        @errors                   = []
        @limit                    = limit
        @maxLinesWidth            = 0
        @additionaInputLines      = additionaInputLines
    end

    def handle(string, index=nil, lines=nil)
        if not string.match(@pattern) or string.empty?
            return false
        end
        string = self.expand_input(string, index, lines)
        line   = self.extract_line(string, index, lines)
        self.add_error(line, string)
        true
    end

    def expand_input(string, index, lines)
        return string if @additionaInputLines == 0
        to = [index + @additionaInputLines, lines.size].min
        return lines[index..to].join("\n") + "\n"
    end

    def extract_line(string, index, lines)
        # force 'line ..' first
        if /line(?:s)? (?<line>[0-9\-]+)/ =~ string
            return line
        end
        if  /(?:line(?:s)? |l[^0-9])(?<line>[0-9\-]+)/ =~ string
            return line
        end
        return "-"
    end

    def render_line(line)
        (@filestate and @filestate.state or "") + line.to_s
    end

    def add_error(line, string)
        return if self.has_error?(line, string) # avoid duplicate errors
        line = self.render_line(line) unless line == "-"
        @errors.push([line, string.to_s])
        @maxLinesWidth = [@maxLinesWidth, line.size].max
    end

    def has_error?(line, string)
        @errors.each { |e|
            return true if e[0] == line and e[1] == string
        }
        false
    end

    def to_s
        if self.empty?
            return ""
        end
        self.sort
        limit = [@limit, @errors.size].min
        str   = @name.red.bold + " [#{@errors.size}]: "
        str   += "\n" #if self.size > 1 and limit > 0
        limit.times { |i|
            str += "    #{self.format_error(@errors[i][0], @errors[i][1])}\n"
        }
        if @limit < @errors.size and @limit != 0
            str += "    #{"...".ljust(@maxLinesWidth)} ...\n"
        end
        #str += "\n"
        str
    end

    def format_error(line, string)
        message = self.format_warning_message(line, string)
        "#{line.ljust(@maxLinesWidth).yellow} #{message.to_s.chomp}"
    end

    def format_warning_message(line, string)
        if @printPattern.instance_of? Proc
            puts self.class, @name
            return @printPattern.call(line, string)
        end
        matched = @printPattern.match string
        return string if not matched
        return matched
    end

    def sort
        # magic from
        # http://www.bofh.org.uk/2007/12/16/comprehensible-sorting-in-ruby
        # for number sensible sorting
        @errors.sort_by {|k|
            k.to_s.split(/((?:(?:^|\s)[-+])?(?:\.\d+|\d+(?:\.\d+?(?:[eE]\d+)?(?:$|(?![eE\.])))?))/ms).
                map {|v| Float(v) rescue v.downcase}
        }
    end

    def size
        @errors.size
    end

    def empty?
        self.size == 0
    end
end

# ============================================================================
class FilenameParser

    def initialize
        @nesting = []
    end

    def filestate=(state)
    end

    def handle(string, index, lines)
        unless string =~ /^\([\.\/]/ || string =~ /^\[[^\]]/ || string =~ /^\)/
            return false
        end
        self.parse(string)
        return true
    end

    def parse(string)
        while string and string != ""

            if string =~ /^\s+(.*)/
                string = $1
            end

            break unless string

            if string =~ /^\[[^\]]+\](.*)/
                string = $1
                next
            end

            if string =~ /^(\)+)(.*)/
                $1.size.times { @nesting.pop }
                break unless $2
                string = $2[1,$2.size]
                next
            end

            if string =~ /^\(([^\(\)\[]+)(.*)/
                @nesting.push($1)
                string = $2
                next
            end

            break
        end
    end

    def empty?
        return true
    end

    def state
        if @nesting.size <= 1
            return ""
        end
        return @nesting[1,@nesting.size].join("|") + ": "
    end
end

# ============================================================================
class OtherWarning < TexWarning
    def initialize(limits=10)
        super('Other Warnings', /LaTeX Warning:/,
              /[^(LaTeX Warning)].*/, limits)
    end
end

class PDFVersionMismatchWarning < TexWarning
    def initialize(limits=10)
        super('PDF Version mismatches', /PDF version/, /found PDF .*/, limits)
    end

    def format_warning_message(line, string)
        result = string.match(/found PDF version <(.*?)>.*?<(.*?)>/)
        "found #{result[1]} instead of #{result[2]}"
    end

    def extract_line(string, index, lines)
        /file (.*?)\):/.match(string)[1]
    end
end

class TooManyWarning < TexWarning
    def initialize(limits=10)
        super('Too Many XYZ Warning', /Too many /, /^l\.[0-9]+ (.*)/, limits)
        @additionaInputLines = 10
    end

    def format_warning_message(line, string)
        @printPattern.match(string)[1]
    end
end


class RepeatedPageNumberWarning < TexWarning
    def initialize(limits=1)
        super('PDF Repeated Page Number',
              /destination with the same identifier \(name\{page\./, limits)
        @additionaInputLines = 4
    end

    def format_warning_message(line, string)
        match = /^l\.[0-9]+ (.*\n.*)/.match(string)[1]
        match.gsub!(/\s*\n\s*/, '')
        name = /^(.*)\)/.match(string)
        if not name.nil?
            name = name[1]
        else
            #fix this
        end
        if line.to_i == 0
            prefix = "\n"
            separator = ""
        else
            prefix = ""
            separator = " "*Math.log(line.to_i).floor
        end
        "#{prefix} near: #{match}.\n#{separator} try using plainpages=false or pdfpagelabels in hyperref
   see: http://en.wikibooks.org/wiki/LaTeX/Hyperlinks#Problems_with_Links_and_Pages"
    end
end


class FontWarning < TexWarning
    def initialize(limits=10)
        super('Font Shape Warnings', /Font Warning: Font shape /, /.*/, limits, 1)
    end
    def format_warning_message(line, message)
        message.sub(/\(Font\)\s+/, '').
            sub("\n", ', ').
            sub(", Font shape", ',').
            match(/Font shape (.*?) on input/)[1]
    end
end

class BibtexWarning < TexWarning
    def initialize(limits=10)
        super('Bibtex Warnings',
              /I found no/,
              /I f.*? command/, limits)
    end
end

class CitationWarning < TexWarning
    def initialize(limit=10)
        super('Citation Undefined',
              pattern=/Warning: Citation/,
              printPattern=/Citation (?<citation>[^ ]+).*on page (?<page>[0-9]+) undefined/, limit=limit)
    end

    def format_warning_message(line, string)
        matched = @printPattern.match string
        "#{matched[:citation][1..-2]} (output page #{matched[:page]})"
    end
end

class ReferenceWarning < TexWarning
    def initialize(limits=1)
        super('Reference Warnings',
              /Warning: Reference/,
              /[^ ]+ on page [0-9]+ undefined/, limits)
    end
end

class MissingParenthesisWarning < TexWarning
    def initialize(source, limits=10)
        super('Missing Parenthesis',
              /File ended /, /[^! ].*/,
              limits)
        @source = source
        @sourceContents = File.read(source)
    end

    def extract_line(string, index, lines)
        label = self.format_warning_message(0, string)
        errorSource = Regexp.escape(lines[index - 1].strip()[0..-6])
        errorSource.gsub!('\\ ', '\s*') # make sure we can match newlines
        lineNumbers = []
        matches = @sourceContents.match(errorSource)
        (0..matches.size-1).each { |i|
            to = matches.begin(i)
            linenumber = @sourceContents[0..to].scan("\n").size + 1
            lineNumbers.push(linenumber)
        }
        lineNumbers.join(',')
    end
end

class PharagraphEndedWarning < TexWarning
    def initialize(source, limits=10)
        super('Runaway Argument',
              /! Pharagraph ended /, /[^! ].*/,
              limits)
        @source = source
        #@sourceContents = File.read(source)
    end

    def extract_line__(string, index, lines)
        label = self.format_warning_message(0, string)
        errorSource = Regexp.escape(lines[index - 1].strip()[0..-6])
        errorSource.gsub!('\\ ', '\s*') # make sure we can match newlines
        lineNumbers = []
        matches = @sourceContents.match(errorSource)
        (0..matches.size-1).each { |i|
            to = matches.begin(i)
            linenumber = @sourceContents[0..to].scan("\n").size + 1
            lineNumbers.push(linenumber)
        }
        lineNumbers.join(',')
    end
end

class MultipleLabelWarning < TexWarning
    def initialize(source, limits=40)
        super('Multiply defined Labels', /LaTeX Warning: Label.*? multiply/,
              /.*/, limits)
        @source = source
    end

    def format_warning_message(line, string)
        string.match(/Label `(.*?)' /)[1]
    end

    def extract_line(string, index, lines)
        label = self.format_warning_message(0, string)
        `sed -ne /\label{#{label}}/= #{@source}`.split.join(',')
    end

end

class TexError < TexWarning
    def initialize(name, pattern, printPattern=/[^!].*/, limit=10)
        super(name, pattern, printPattern, limit)
    end

    def extract_line(string, index, lines)
        match =  /(?:line(?:s)? |l.)([0-9\-]+( \\.*)?)/
        if string =~ match
            return $1.to_s
        end
        (index+1).upto(lines.size-1) { |i|
            return "-" if lines[i].start_with? "!"
            if lines[i] =~ match
                return $1.to_s
            end
        }
        return "-"
    end
end

#  vim: set ts=4 sw=4 ts=4 :

