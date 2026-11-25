-- Soker mejl till eller fran en adress i Mail.
--
-- Anropas som: osascript mail-sok.applescript <adress> <max antal per lada>
--
-- Gransen galler per lada, inte totalt. Annars skulle inkorgen fylla hela
-- kvoten och skickade mejl aldrig komma med. Anroparen sorterar pa datum.
-- Svarar med en rad per mejl, falten atskilda av ASCII 31 (unit separator),
-- eftersom amnesrader garna innehaller bade tabbar och rortecken.
--
-- AppleScript-identifierare maste vara ASCII, darav stavningen har.
-- Kommentarer far daremot innehalla å ä ö.
--
-- Inkorgen filtreras på avsändare, skickat på mottagare. Att filtrera på
-- avsändare även i skickat vore meningslöst: där är avsändaren alltid jag.

on run argv
	set adress to item 1 of argv
	set grans to (item 2 of argv) as integer
	set faltdelare to (ASCII character 31)
	set ut to ""

	tell application "Mail"
		repeat with konto in accounts
			set kontonamn to name of konto

			-- Inkorgen: mejl från personen. Exakt adress, inom <> eller ensam:
			-- "contains adress" tog också hanna@ och johanna@ när kontakten
			-- var anna@, och deras mejl hamnade i kundens kunskapsbank.
			set raknare to 0
			try
				set traffar to (every message of mailbox "INBOX" of konto whose sender contains ("<" & adress & ">") or sender is adress)
				repeat with m in traffar
					if raknare >= grans then exit repeat
					set raknare to raknare + 1
					set ut to ut & my rad(m, kontonamn, "INBOX", "fran", faltdelare)
				end repeat
			end try

			-- Skickat: mejl till personen.
			-- "sent mailbox of konto" finns inte i Mails ordlista, och lådan
			-- heter olika beroende på konto och språk, så namnen provas i tur.
			set raknare to 0
			repeat with kandidat in {"Sent Messages", "Sent", "Skickat", "Skickade objekt"}
				try
					set skickat to mailbox (kandidat as string) of konto
					set traffar to (every message of skickat whose (address of every to recipient) contains adress)
					repeat with m in traffar
						if raknare >= grans then exit repeat
						set raknare to raknare + 1
						set ut to ut & my rad(m, kontonamn, kandidat as string, "till", faltdelare)
					end repeat
					exit repeat
				end try
			end repeat
		end repeat
	end tell
	return ut
end run

on rad(m, kontonamn, ladnamn, riktning, faltdelare)
	tell application "Mail"
		try
			set d to (date received of m) as string
		on error
			try
				set d to (date sent of m) as string
			on error
				set d to ""
			end try
		end try
		try
			set a to sender of m
		on error
			set a to ""
		end try
		try
			set s to subject of m
		on error
			set s to "(utan amne)"
		end try
		-- Brödtexten är ofta det som betyder något; ämnesraden säger sällan
		-- vad som faktiskt stod. Kapas för att svaret inte ska bli ohanterligt.
		try
			set b to content of m
			if (count of b) > 4000 then set b to (text 1 thru 4000 of b)
			-- Radbrytningar skulle bryta radformatet; de blir mellanslag.
			set gamla to AppleScript's text item delimiters
			set AppleScript's text item delimiters to {linefeed, return, tab}
			set delar to text items of b
			set AppleScript's text item delimiters to " "
			set b to delar as string
			set AppleScript's text item delimiters to gamla
		on error
			set b to ""
		end try
		try
			set mid to message id of m
		on error
			set mid to ""
		end try
		return d & faltdelare & a & faltdelare & s & faltdelare & mid & faltdelare & kontonamn & faltdelare & ladnamn & faltdelare & riktning & faltdelare & b & linefeed
	end tell
end rad
