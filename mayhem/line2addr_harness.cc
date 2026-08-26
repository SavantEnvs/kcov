/*
 * mayhem/line2addr_harness.cc — the `line2addr` fuzz target.
 *
 * Derived from upstream's tools/line2addr.cc (same CLI, same code path: kcov's
 * ELF + DWARF parser stack under src/parsers). Upstream's tool is a demo that is
 * NOT usable as a fuzz target as-is; two additive fixes are made here, both of
 * which are *setup* the tool forgets to do — no parser behaviour is changed:
 *
 *  1. setupParser(&filter).  ElfInstance::m_filter starts NULL and is only ever
 *     assigned by IFileParser::setupParser(), which upstream calls from
 *     src/main.cc but NOT from tools/line2addr.cc.  ElfInstance::onLine()
 *     (src/parsers/elf-parser.cc:406) then does `m_filter->mangleSourcePath(..)`
 *     — a virtual call through a null pointer on the FIRST source line found in
 *     any input.  With the halting sanitizers this aborts on every well-formed
 *     ELF that carries debug info, so the fuzzer can never get past the first
 *     line of the first compilation unit.  We pass IFilter::createBasic() (an
 *     allow-everything filter whose mangleSourcePath() is the identity), which
 *     is what kcov itself installs for this code path.
 *
 *  2. parse-solibs = 0.  ElfInstance::parse() (elf-parser.cc:190) SKIPS parsing
 *     entirely for a shared/PIE object (ET_DYN) when the `parse-solibs` config
 *     key is set — kcov defers those until the dynamic loader reports the load
 *     address, which never happens outside a real ptrace session.  The key
 *     defaults to 1, so with upstream's tool a PIE input (i.e. essentially every
 *     modern binary) parses NOTHING: no sections, no DWARF, no lines.  Clearing
 *     it makes parse() take the setMainFileRelocation(0) path, which parses the
 *     file at relocation 0 — the ELF/DWARF work we actually want to fuzz.
 *
 * Usage is unchanged: line2addr <in-file> <file-pattern> [line-nr]
 */
#include <configuration.hh>
#include <file-parser.hh>
#include <filter.hh>
#include <utils.hh>

using namespace kcov;

const char *kcov_version = "";

class Listener : public IFileParser::ILineListener
{
public:
	Listener(IFileParser &parser, const std::string &filePattern, int lineNr) :
		m_filePattern(filePattern),
		m_lineNr(lineNr)
	{
		parser.registerLineListener(*this);
	}

	virtual ~Listener()
	{
	}

	void onLine(const std::string &file, unsigned int lineNr, uint64_t addr)
	{
		if (file.find(m_filePattern) != std::string::npos) {
			if (m_lineNr < 0 || lineNr == (unsigned int)m_lineNr)
				report(addr);
		}
	}

private:
	void report(unsigned long addr)
	{
		printf("0x%lx\n", addr);
	}

	const std::string m_filePattern;
	const int m_lineNr;
};

int main(int argc, const char *argv[])
{
	if (argc < 3) {
		fprintf(stderr, "Usage: line2addr in-file file-pattern [line-nr]\n");
		return 1;
	}

	std::string file(argv[1]);
	std::string fileName(argv[2]);
	int lineNr = -1;

	if (argc >= 4) {
		if (!string_is_integer(argv[3])) {
			fprintf(stderr, "line-nr argument (%s) must be integer\n", argv[3]);
			return 1;
		}

		lineNr = string_to_integer(argv[3]);
	}

	// (2) parse ET_DYN/PIE inputs here and now instead of deferring them to a
	//     ptrace session that does not exist in this tool.
	IConfiguration::getInstance().setKey("parse-solibs", 0);

	IFileParser *parser = IParserManager::getInstance().matchParser(file);
	if (!parser) {
		fprintf(stderr, "Can't match parser for %s\n", file.c_str());
		return 1;
	}

	// (1) the setup upstream's tools/line2addr.cc omits — without it every
	//     source line found dereferences a null IFilter.
	IFilter &filter = IFilter::createBasic();
	parser->setupParser(&filter);

	Listener listener(*parser, fileName, lineNr);

	// NB: upstream ignores addFile()'s return value and calls parse() regardless —
	// keep that, it is part of the code path under test.
	parser->addFile(file);

	return parser->parse() ? 0 : 1;
}
