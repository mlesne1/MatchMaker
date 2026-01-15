--[[
	RegionCodes

	Maps ISO 3166-1 alpha-2 country codes to matchmaking region identifiers.
	Used by MatchMakerService to automatically assign players to regional queues.

	Purpose:
		- Groups players by geographic proximity for lower latency matches
		- Balances queue population across regions
		- Provides fallbacks for countries without dedicated regions

	How It's Used:
		When AddPartyAsync() is called without a RegionCode:
		1. MatchMakerService gets the player's country via LocalizationService
		2. Looks up the country code in this table
		3. Uses the mapped region code for queue assignment
		4. Falls back to DEFAULT if country not found

	Region Codes:
		NA   - North America (US, Canada)
		BR   - Brazil (dedicated due to population)
		LAN  - Latin America North (Mexico, Central America, Caribbean)
		LAS  - Latin America South (Argentina, Chile, etc.)
		EUW  - Europe West (UK, France, Germany, etc.)
		EUNE - Europe Nordic & East (Poland, Romania, etc.)
		TR   - Turkey
		RU   - Russia & CIS
		KR   - Korea
		JP   - Japan
		SEA  - Southeast Asia (Singapore, Malaysia, etc.)
		OCE  - Oceania (Australia, New Zealand)

	Adding New Countries:
		1. Find the ISO 3166-1 alpha-2 code (e.g., "FR" for France)
		2. Add it to the appropriate region section
		3. Format: COUNTRY_CODE = "REGION_CODE",

	Fallback Strategy:
		- Middle East & North Africa → EUW (closest infrastructure)
		- Unmapped countries → DEFAULT (EUW)
		- Antarctica → NA (just in case 🐧)

	Cross-Region Fallback:
		When parties wait too long (> CROSS_REGION_TIMEOUT), they become eligible
		for matching with parties from fallback regions. The RegionFallbacks table
		defines the fallback chain for each region, ordered by:
		1. Geographic proximity (lower latency)
		2. Expected player population (better queue times)

	Example Usage:
		local RegionCodes = require(path.to.RegionCodes)

		local countryCode = "US"
		local region = RegionCodes.CountryCodes[countryCode] or RegionCodes.CountryCodes.DEFAULT
		print(region) -- "NA"

		-- Get fallback regions for cross-region matching
		local fallbacks = RegionCodes.RegionFallbacks["NA"]
		print(fallbacks) -- {"EUW", "BR", "LAN"}

	Notes:
		- Country codes are from LocalizationService:GetCountryRegionForPlayerAsync()
		- Region selection affects queue times and match latency
		- Consider player population when adding new regions
]]--

--[[
	RegionFallbacks

	Defines the fallback chain for cross-region matchmaking.
	When parties wait longer than CROSS_REGION_TIMEOUT, coordinators
	will also fetch eligible parties from these fallback regions.

	Order matters:
		- First fallback = closest/most similar region
		- Last fallback = last resort

	Considerations:
		- Geographic proximity (latency)
		- Language/culture similarity
		- Player population overlap (time zones)
]]--
local RegionFallbacks = {
	-- North America: Try Europe (English), then Brazil, then Latin America
	NA   = { "EUW", "BR", "LAN" },

	-- Brazil: Try Latin America South, then North America
	BR   = { "LAS", "LAN", "NA" },

	-- Latin America North: Try NA (closest), then Brazil, then LAS
	LAN  = { "NA", "BR", "LAS" },

	-- Latin America South: Try Brazil, then LAN, then NA
	LAS  = { "BR", "LAN", "NA" },

	-- Europe West: Try EUNE first (same continent), then NA (English)
	EUW  = { "EUNE", "NA", "TR" },

	-- Europe Nordic & East: Try EUW, then Russia, then Turkey
	EUNE = { "EUW", "RU", "TR" },

	-- Turkey: Try EUNE (closest), then EUW, then Russia
	TR   = { "EUNE", "EUW", "RU" },

	-- Russia: Try EUNE (closest EU), then EUW, then Korea
	RU   = { "EUNE", "EUW", "KR" },

	-- Korea: Try Japan (closest), then SEA, then NA
	KR   = { "JP", "SEA", "NA" },

	-- Japan: Try Korea (closest), then SEA, then NA
	JP   = { "KR", "SEA", "NA" },

	-- Southeast Asia: Try OCE, then Korea, then Japan
	SEA  = { "OCE", "KR", "JP" },

	-- Oceania: Try SEA (closest), then NA, then Japan
	OCE  = { "SEA", "NA", "JP" },
}

--[[
	CountryCodes

	Maps ISO 3166-1 alpha-2 country codes to region identifiers.
]]--
local CountryCodes = {

	-- North America
	US = "NA",  -- United States
	CA = "NA",  -- Canada

	-- Brazil (dedicated region due to large player base)
	BR = "BR",  -- Brazil

	-- Latin America North (Central America & Caribbean)
	MX = "LAN", -- Mexico
	CR = "LAN", -- Costa Rica
	GT = "LAN", -- Guatemala
	PA = "LAN", -- Panama
	DO = "LAN", -- Dominican Republic
	SV = "LAN", -- El Salvador
	NI = "LAN", -- Nicaragua
	HN = "LAN", -- Honduras
	PR = "LAN", -- Puerto Rico

	-- Latin America South
	AR = "LAS", -- Argentina
	CL = "LAS", -- Chile
	CO = "LAS", -- Colombia
	EC = "LAS", -- Ecuador
	PE = "LAS", -- Peru
	UY = "LAS", -- Uruguay
	VE = "LAS", -- Venezuela
	PY = "LAS", -- Paraguay
	BO = "LAS", -- Bolivia

	-- Western Europe
	GB = "EUW", -- United Kingdom
	FR = "EUW", -- France
	DE = "EUW", -- Germany
	NL = "EUW", -- Netherlands
	BE = "EUW", -- Belgium
	IE = "EUW", -- Ireland
	CH = "EUW", -- Switzerland
	AT = "EUW", -- Austria
	DK = "EUW", -- Denmark
	NO = "EUW", -- Norway
	SE = "EUW", -- Sweden
	FI = "EUW", -- Finland
	IS = "EUW", -- Iceland
	PT = "EUW", -- Portugal
	ES = "EUW", -- Spain
	IT = "EUW", -- Italy
	LU = "EUW", -- Luxembourg

	-- Europe Nordic & East
	PL = "EUNE", -- Poland
	RO = "EUNE", -- Romania
	HU = "EUNE", -- Hungary
	SK = "EUNE", -- Slovakia
	CZ = "EUNE", -- Czech Republic
	SI = "EUNE", -- Slovenia
	BG = "EUNE", -- Bulgaria
	GR = "EUNE", -- Greece
	HR = "EUNE", -- Croatia
	EE = "EUNE", -- Estonia
	LT = "EUNE", -- Lithuania
	LV = "EUNE", -- Latvia
	BA = "EUNE", -- Bosnia and Herzegovina
	ME = "EUNE", -- Montenegro
	MK = "EUNE", -- North Macedonia
	RS = "EUNE", -- Serbia
	AL = "EUNE", -- Albania

	-- Turkey
	TR = "TR",  -- Turkey
	CY = "TR",  -- Cyprus

	-- Russia & CIS
	RU = "RU",  -- Russia
	KZ = "RU",  -- Kazakhstan
	UA = "RU",  -- Ukraine

	-- Korea & Japan (dedicated regions)
	KR = "KR",  -- South Korea
	JP = "JP",  -- Japan

	-- Southeast Asia
	SG = "SEA", -- Singapore
	MY = "SEA", -- Malaysia
	ID = "SEA", -- Indonesia
	TH = "SEA", -- Thailand
	PH = "SEA", -- Philippines
	VN = "SEA", -- Vietnam
	HK = "SEA", -- Hong Kong
	TW = "SEA", -- Taiwan

	-- Oceania
	AU = "OCE", -- Australia
	NZ = "OCE", -- New Zealand

	-- Middle East & North Africa → EUW (closest backbone)
	AE = "EUW", -- United Arab Emirates
	SA = "EUW", -- Saudi Arabia
	IL = "EUW", -- Israel
	EG = "EUW", -- Egypt
	MA = "EUW", -- Morocco
	DZ = "EUW", -- Algeria
	TN = "EUW", -- Tunisia

	-- Africa → EUW (closest infrastructure)
	ZA = "EUW", -- South Africa
	NG = "EUW", -- Nigeria
	KE = "EUW", -- Kenya

	-- Edge cases
	AQ = "NA",  -- Antarctica
	GS = "NA",  -- South Georgia
	FK = "LAS", -- Falkland Islands

	-- Default fallback for unmapped countries
	DEFAULT = "EUW",
}

-- Export both tables
return {
	CountryCodes = CountryCodes,
	RegionFallbacks = RegionFallbacks,
}