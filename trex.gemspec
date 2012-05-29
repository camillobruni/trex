Gem::Specification.new do |s|
  s.name         = 'trex'
  s.executables  << 'trex'
  s.version      = '1.0.5'
  s.date         = '2012-05-29'
  s.summary      = "Automate compilation of LaTeX documents, making the output human-readable."
  s.description  = "trex is script simplifying the compilation of latex files by creating proper human-readable error output with repeating patterns. Unlike the original latex output which is oververbosified."
  s.authors      = ["Camillo Bruni", "Toon Verwaest", "Damien Pollet"]
  s.email        = 'camillorbuni@cxg.ch'
  s.files        = ["lib/trex.rb"]
  s.homepage     = "https://github.com/dh83/trex"
  s.add_dependency('term-ansicolor',  '>= 1.0.7')
end
