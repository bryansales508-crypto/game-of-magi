local module = {}

--TODO: When you add the capability for races or anything that needs to overide the default, just set it up after the main if statements. Whatever last set to ID is what the game will take.

module.facebase = function(stat)
	local facebasetable = {
		fana = {
			"rbxassetid://13467064968", --New Facebase v1
			"rbxassetid://13467064968" --New Facebae v1
		},
		human = {
			female = {
				"rbxassetid://13473200175",
				"rbxassetid://13473200175" --Same as the other one until I make the pupils
			},
			male = {
				"rbxassetid://13466958587",
				"rbxassetid://13473204337"
			},
		}
	}

	local id
	if stat["Gender"].Value == 1 then
		if stat["FaceBase"].Value == 1 then
			id = facebasetable.human.male[1]
		else
			id = facebasetable.human.male[2]
		end
	else
		id = facebasetable.human.female[1]
	end

	local facebase = Instance.new("Decal")
	facebase.Name = "FaceBase"
	facebase.Texture = id

	return facebase
end

module.eyecolor = function(stat)
	local eyecolortable = {
		human = {
			"rbxassetid://13466965920", -- New Blue
			"rbxassetid://13466968191", -- New Hetero
			"rbxassetid://13466970688", -- New Brown
			"rbxassetid://13466973055", -- New Green
			"rbxassetid://13466975225" -- New Black
		},
		magician = {
			"rbxassetid://13466977547", -- New Red
			"rbxassetid://13466980218", -- New Pink
			"rbxassetid://13466982279", -- New Golden
			"rbxassetid://13466984522", -- New Cyan
			"rbxassetid://13466987017" -- New Hetero
		},
		specialpupil = {
			"rbxassetid://13530055991", --Saluja
			"rbxassetid://13530059043", --Black Hair Ren
			"rbxassetid://16865383522", --Jamil 
			"rbxassetid://18278038510", --Golden
		}
	}

	local id

	-- L2: this used to read `~= 4 or ~= 5`, which is always true (a number
	-- can't equal both), so the magician branch below could never run.
	if stat["Race"].Value == 4 or stat["Race"].Value == 5 then
		id = eyecolortable.magician[stat["EyeColor"].Value]
	else
		id = eyecolortable.human[stat["EyeColor"].Value]
	end

	local eyecolor = Instance.new("Decal")
	eyecolor.Name = "EyeColor"
	eyecolor.Texture = id

	return eyecolor
end

module.mouthshape = function(stat)
	local mouthshapetable = {
		"rbxassetid://13473691312",
		"rbxassetid://13473692702",
		"rbxassetid://13473694214",
		"rbxassetid://13473696669",
		"rbxassetid://13548799920",
		"rbxassetid://13473699264"
	}

	local id = mouthshapetable[stat["MouthShape"].Value]

	local mouthshape = Instance.new("Decal")
	mouthshape.Name = "MouthShape"
	mouthshape.Texture = id

	return mouthshape
end

module.eyebrow = function(stat)
	local eyebrowtable = {
		male = {
			"rbxassetid://13467008369",
			"rbxassetid://13473229358"
		},
		female = {
			"rbxassetid://13467008369",
		}
	}

	local id
	if stat["Gender"].Value == 1  then
		if stat["FaceBase"].Value == 1 then
			id = eyebrowtable.male[1]
		else
			id = eyebrowtable.male[2]
		end
	else
		id = eyebrowtable.female[1]
	end

	local eyebrow = Instance.new("Decal")
	eyebrow.Name = "Eyebrow"
	eyebrow.Color3 = stat["HairColor"].Value
	eyebrow.Texture = id

	return eyebrow 
end

module.coloring = function(chara, t)
	local colortable = {
		Color3.fromRGB(255,255,255), -- Default / White
		Color3.fromRGB(239, 215, 176), -- Tan
		Color3.fromRGB(95, 95, 95) -- Black
	}

	chara:WaitForChild("Shirt").Color3 = colortable[tonumber(t)]
	chara:WaitForChild("Pants").Color3 = colortable[tonumber(t)]
end



module.markings = {
	fana = {
		"rbxassetid://13445662816",
		"rbxassetid://13548675277",
		"rbxassetid://13548678375",
		"rbxassetid://13548685137",
		"rbxassetid://13445667897"
	},
	human = {
		"rbxassetid://13529126618",
	}
}
--fix for 2 rbxassetid://13548675277 (left eyebrow)
--fix for

module.FirstNames = {
	kou = {
		male = {
			"Akira",
			"Haruki",
			"Kenji",
			"Ryo",
			"Yuki",
			"Kazuki",
			"Hiroshi",
			"Takashi",
			"Toshiro",
			"Daichi",
			"Kaito",
			"Haruto",
			"Riku",
			"Yusuke",
			"Masato",
			"Satoshi",
			"Tatsuya",
			"Koji",
			"Yoshihiro",
			"Naoki",
			"Ryota",
			"Kazuya",
			"Kento",
			"Haruka",
			"Yuma",
			"Shota",
			"Keisuke",
			"Takumi",
			"Taichi",
			"Kota",
			"Yosuke",
			"Tomoya",
			"Kazuma",
			"Hikaru",
			"Ryosuke",
			"Hideki",
			"Jun",
			"Ryota",
			"Sora",
			"Makoto",
			"Kosuke",
			"Koki",
			"Yuya",
			"Yuji",
			"Hiroki",
			"Shinji",
			"Shunsuke",
			"Sora",
			"Noboru",
			"Haruka",
			"Takaya",
			"Kenta",
			"Takeru",
			"Kazuhiro",
			"Hirofumi",
			"Daiki",
			"Keita",
			"Ren",
			"Yoshiaki",
			"Mamoru",
			"Tetsuya",
			"Hideyoshi",
			"Kojiro",
			"Kazuki",
			"Kazuo",
			"Ryoma",
			"Shinichi",
			"Tsubasa",
			"Sho",
			"Shingo",
			"Kiyoshi",
			"Tsuyoshi",
			"Shun",
			"Isamu",
			"Akio",
			"Jiro",
			"Teruo",
			"Kenshiro",
			"Yasuo",
			"Ryuji",
			"Kazunari",
			"Hiroyuki",
			"Shuichi",
			"Taro",
			"Yoshio",
			"Yukio",
			"Kazuyoshi",
			"Satoshi",
			"Tetsuo",
			"Kouji",
			"Minoru",
			"Takao",
			"Tadao",
			"Hajime",
			"Yoshiro",
			"Yoshirou"
		},
		female = {
			"Ai",
			"Hana",
			"Kaori",
			"Yumi",
			"Emi",
			"Miyu",
			"Haruka",
			"Sakura",
			"Akari",
			"Ayumi",
			"Mio",
			"Rina",
			"Natsumi",
			"Sora",
			"Aya",
			"Nana",
			"Yui",
			"Yuna",
			"Akane",
			"Mika",
			"Megumi",
			"Airi",
			"Yuka",
			"Riko",
			"Yoko",
			"Nao",
			"Eri",
			"Maki",
			"Akiko",
			"Misaki",
			"Rika",
			"Mayu",
			"Miku",
			"Risa",
			"Akemi",
			"Haru",
			"Miho",
			"Miu",
			"Kanna",
			"Miyuki",
			"Hinata",
			"Karin",
			"Aina",
			"Nanami",
			"Mashiro",
			"Rumi",
			"Arisa",
			"Yuriko",
			"Asumi",
			"Akira",
			"Erika",
			"Yuri",
			"Rin",
			"Aoi",
			"Mariko",
			"Yukiko",
			"Kana",
			"Tomoko",
			"Satsuki",
			"Kotone",
			"Satomi",
			"Yumi",
			"Kaede",
			"Miwa",
			"Aiko",
			"Yurie",
			"Yurika",
			"Hinako",
			"Yuko",
			"Miyako",
			"Chika",
			"Ren",
			"Natsuki",
			"Hikari",
			"Saki",
			"Shiori",
			"Chisato"
		}
	},
	sindria = {
		male = {
			"Aadam",
			"Adil",
			"Ahmad",
			"Ahmed",
			"Ahsan",
			"Akram",
			"Ali",
			"Ali-Shār",
			"Ammar",
			"Amir",
			"Anwar",
			"Armakan",
			"Aqua",
			"Barakat",
			"Bahir",
			"Bilal",
			"Cassim",
			"Dar",
			"Dawood",
			"Ehsan",
			"Faaid",
			"Fahad",
			"Faisal",
			"Farhan",
			"Habib",
			"Haidar",
			"Hakam",
			"Hamza",
			"Harun",
			"Hassan",
			"Ibn-Kathir",
			"Ibrahim",
			"Imran",
			"Ismaeel",
			"Ja'far",
			"Jamal",
			"Jamil",
			"Kahir",
			"Kareem",
			"Karim",
			"Khalid",
			"Lutfi",
			"Majid",
			"Mahmoud",
			"Mohammad",
			"Mohammed",
			"Mostafa",
			"Mustafa",
			"Nabil",
			"Nadir",
			"Nassar",
			"Nasser",
			"Nasir",
			"Omar",
			"Qasim",
			"Rafi",
			"Rami",
			"Rashid",
			"Rasheeq",
			"Saaid",
			"Saabiq",
			"Saeed",
			"Salim",
			"Shahryār",
			"Shirin",
			"Sinbad",
			"Tariq",
			"Umar",
			"Usman",
			"Waleed",
			"Yasin",
			"Yusuf",
			"X",
			"Zahir",
			"Zayn",
			"Zubair"
		},
		female = {
			"Aaliyah",
			"Aalimah",
			"Aisha",
			"Aleena",
			"Amal",
			"Amani",
			"Amina",
			"Amira",
			"Arwa",
			"Aysha",
			"Ayesha",
			"Aziza",
			"Dalia",
			"Farah",
			"Fadwa",
			"Fariha",
			"Fatima",
			"Firdaus",
			"Hafsa",
			"Hana",
			"Hanan",
			"Huda",
			"Iman",
			"Inaya",
			"Jamila",
			"Jamilah",
			"Jasmine",
			"Karima",
			"Khadija",
			"Khalida",
			"Khawla",
			"Laila",
			"Layla",
			"Lina",
			"Lubna",
			"Malika",
			"Maha",
			"Maryam",
			"Mariam",
			"Muna",
			"Nadia",
			"Nadiya",
			"Naima",
			"Na'ima",
			"Nabilah",
			"Nasira",
			"Nasreen",
			"Noor",
			"Nora",
			"Rabia",
			"Rabiah",
			"Rahma",
			"Rania",
			"Rayhana",
			"Rima",
			"Safa",
			"Safia",
			"Sahar",
			"Sakina",
			"Salma",
			"Samar",
			"Samia",
			"Samira",
			"Sana",
			"Saida",
			"Sara",
			"Shadia",
			"Shazia",
			"Sofia",
			"Soraya",
			"Sumaya",
			"Yara",
			"Yasmin",
			"Yusra",
			"Zahira",
			"Zahra",
			"Zahrah",
			"Zaina",
			"Zainab",
			"Zainah",
			"Zara",
			"Zaynab",
			"Zoya"
		}
	},

	reim = {
		male = {
			"Alexander",
			"Damian",
			"Elias",
			"Iason",
			"Jason",
			"Theodore",
			"Pluto",
			"Sokratis",
			"Nicholas",
			"Lucas",
			"Christopher",
			"Ethan",
			"Apollo",
			"Atlas",
			"Cyrus",
			"Damon",
			"Evander",
			"Felix",
			"Gregory",
			"Hector",
			"Ian",
			"Nikandros",
			"Leo",
			"Maximus",
			"Nathan",
			"Oliver",
			"Philip",
			"Quentin",
			"Roman",
			"Samuel",
			"Thomas",
			"Ulysses",
			"Victor",
			"William",
			"Xander",
			"Yannis",
			"Zachary",
			"Achilles",
			"Basil",
			"Callum",
			"Dante",
			"Elijah",
			"Finn",
			"Gideon",
			"Hugo",
			"Icarus",
			"Julian",
			"Demacles",
			"Leander",
			"Matthias",
			"Alexios",
			"Orion",
			"Percy",
			"Quincy",
			"Raphael",
			"Seamus",
			"Thaddeus",
			"Uriel",
			"Barnabas",
			"Willem",
			"Xavier",
			"Yves",
			"Petros",
			"Adam",
			"Leonidas",
			"Caleb",
			"Daniel",
			"Evan",
			"Frederick",
			"Vasilios",
			"Henry",
			"Ian",
			"Kallinikos",
			"Kieran",
			"Liam",
			"Ermis",
			"Nolan",
			"Owen",
			"Petros",
			"Quentin",
			"Ryan",
			"Samuel",
			"Odisseas",
			"Vincent",
			"Miltiadis",
			"Xavier",
			"Yosef",
			"Zachary"
		},
		female = {
			"Alexandra",
			"Aphrodite",
			"Ariadne",
			"Athena",
			"Calliope",
			"Cassandra",
			"Chloe",
			"Cleo",
			"Daphne",
			"Demetra",
			"Eleni",
			"Elena",
			"Elysia",
			"Evangeline",
			"Helena",
			"Hermione",
			"Iris",
			"Isadora",
			"Kalliope",
			"Kyra",
			"Larissa",
			"Lydia",
			"Melina",
			"Natalia",
			"Nikoleta",
			"Ophelia",
			"Penelope",
			"Phoebe",
			"Sophia",
			"Thalia",
			"Xenia",
			"Zoe",
			"Adriana",
			"Agatha",
			"Agnes",
			"Althea",
			"Anastasia",
			"Andromeda",
			"Angelina",
			"Athena",
			"Aurora",
			"Cassandra",
			"Charlotte",
			"Cynthia",
			"Diana",
			"Elara",
			"Elena",
			"Elizabeth",
			"Eva",
			"Fiona",
			"Georgia",
			"Harmony",
			"Helen",
			"Irene",
			"Isabella",
			"Jasmine",
			"Julia",
			"Katherine",
			"Laura",
			"Liliana",
			"Maria",
			"Nadia",
			"Natasha",
			"Nina",
			"Olympia",
			"Pandora",
			"Patricia",
			"Phaedra",
			"Rhea",
			"Sabrina",
			"Sophia",
			"Tatiana",
			"Valentina",
			"Vanessa",
			"Victoria",
			"Xanthe",
			"Yasmine",
			"Zara"
		}
	},

	immu = {
		"Pipiruka",
		"Rurumoa",
		"Kikigaa",
		"Bobobesi",
		"Gogomau",
		"Tantanvu",
		"Rorodai",
		"Lalanu",
		"Mumuna",
		"Kakalai",
		"Duduky",
		"Wawaram",
		"Gigishi",
		"Nananza",
		"Zazami",
		"Fufuna",
		"Huhutu",
		"Popoma",
		"Sisiko",
		"Vuvuru",
		"Lalawo",
		"Memeko",
		"Kokose",
		"Xoxozo",
		"Titiba",
		"Ririne",
		"Ziziba",
		"Mavadodo",
		"Jajala",
		"Kukude",
		"Gogoke",
		"Wewelo",
		"Bubuso",
		"Raraku",
		"Luluyi",
		"Didija",
		"Mumupa",
		"Pipine",
		"Gugupo",
		"Fafasu",
		"Wawaya",
		"Yoyozo",
		"Bobole",
		"Pupuya",
		"Gogori",
		"Loloril",
		"Tontonpu",
		"Sosoma",
		"Nanani",
		"Ruruko",
		"Vovova",
		"Cacahi",
		"Tatasa",
		"Zozoko",
		"Kikipe",
		"Pupruru",
		"Dululu",
		"Huhuya",
		"Xaxase",
		"Neneno",
		"Ziziri",
		"Fefeda",
		"Rorowo",
		"Wawasi",
		"Lelala",
		"Mimipe",
		"Bubumu",
		"Gagaku",
		"GioGio",
		"Pupuya",
		"Raraso",
		"Jotoaroro",
		"Gogolu",
		"Lulusi",
		"Sisina",
		"Tonton",
		"Ririka",
		"Memelo",
		"Duduko",
		"Kukupa",
		"DioDio",
		"Wewena",
		"JoJo",
		"Pipidan",
		"Gugururu",
		"Lirinene",
		"Mawawa",
		"Nananu",
	},
}

module.LastNames = {
	kou = {
		"Ren",
		"Ren",
		"Sakura",
		"Yuki",
		"Emi",
		"Ren",
		"Airi",
		"Kaito",
		"Yumi",
		"Hiroshi",
		"Aya",
		"Yuto",
		"Rina",
		"Sora",
		"Mei",
		"Kazuki",
		"Hana",
		"Daichi",
		"Mai",
		"Ryota",
		"Yui",
		"Ryo",
		"Nana",
		"Kenta",
		"Eri"
	},

	sindria = {
		"Saluja",
		"Jamil",
		"Ali-Hassan",
		"Siddiqui-Rahman",
		"Sheikh-Farooq",
		"Siddiqui-Rahman",
		"Sheikh-Farooq",
		"Qureshi-Ahmed",
		"Hashmi-Abbas",
		"Zahoor-Haq",
		"Akhtar-Islam",
		"Mustafa-Saeed",
		"Yusuf-Ahmadi",
		"Qazi-Kazmi",
		"Raza-Qadir",
		"Zaidi-Nawaz",
		"Khan-Zaman",
		"Jamal-Nasir",
		"Ali-Jalal",
		"Ahmed-Qureshi",
		"Malik-Ahmed",
		"Khan-Malik"
	},

	reim = {
		"au Andromedus",
		"au Andromedus",
		"Athanasios",
		"Callias",
		"Demetriou",
		"Evangelos",
		"Georgiou",
		"Ioannidis",
		"Kasimatis",
		"Lazaridis",
		"Mavridis",
		"Nikolaidis",
		"Orfanos",
		"Papadopoulos",
		"Roussos",
		"Sotiriou",
		"Theodosiou",
		"Vasilopoulos",
		"Xenakis",
		"Yiannopoulos",
		"Zervos",
		"Argyropoulos",
		"Bakas",
		"Chrysanthopoulos",
		"Daskalakis",
		"Fotopoulos" 
	},
}

module.clothing = {
	immu = {
		random = {
			shirts = {
				"http://www.roblox.com/asset/?id=5901002613",
				"http://www.roblox.com/asset/?id=6462839647",
				"http://www.roblox.com/asset/?id=6462739097",


			},
			pants = {
				male = {
					"http://www.roblox.com/asset/?id=6460029645",
					"http://www.roblox.com/asset/?id=6463819864",
				},

				female = {
					"http://www.roblox.com/asset/?id=6463819864",
				}
			}
		}
	},

	kou = {
		random = {
			shirts = {
				"http://www.roblox.com/asset/?id=13425074037",
				"http://www.roblox.com/asset/?id=10789500905",
				"http://www.roblox.com/asset/?id=10789502284",
				"http://www.roblox.com/asset/?id=13425102782",
				"http://www.roblox.com/asset/?id=6266116044",
				"http://www.roblox.com/asset/?id=322372145",
				"http://www.roblox.com/asset/?id=342466012",
				"http://www.roblox.com/asset/?id=5377052570",
				"http://www.roblox.com/asset/?id=1674188381",
				"http://www.roblox.com/asset/?id=4749086985",
				"http://www.roblox.com/asset/?id=7529388736",
				"http://www.roblox.com/asset/?id=2685394071",
				"http://www.roblox.com/asset/?id=6044505862",
				"http://www.roblox.com/asset/?id=488061262"


			},
			pants = {
				"http://www.roblox.com/asset/?id=10813647504",
				"http://www.roblox.com/asset/?id=6704522233"
			}
		},
		sorted = {
			male = {
				"http://www.roblox.com/asset/?id=514216850",
				"http://www.roblox.com/asset/?id=11440573751",

				"http://www.roblox.com/asset/?id=13308189019",
				"http://www.roblox.com/asset/?id=13308202849"
			},
			female = {
				"http://www.roblox.com/asset/?id=2302840426",
				"http://www.roblox.com/asset/?id=2302844336",

				"http://www.roblox.com/asset/?id=13317883539",
				"http://www.roblox.com/asset/?id=13317889548"
			}
		}
	},

	sindria = {
		random = {
			pants = {
				male = {
					"http://www.roblox.com/asset/?id=558350552",
					"http://www.roblox.com/asset/?id=10466902361",
					"http://www.roblox.com/asset/?id=8115028065",
					"http://www.roblox.com/asset/?id=4464134110",
					"http://www.roblox.com/asset/?id=8572547653"
				},
				female = {
					"http://www.roblox.com/asset/?id=5618835761",
					"http://www.roblox.com/asset/?id=8572547653",
					"http://www.roblox.com/asset/?id=5001556420",
					"http://www.roblox.com/asset/?id=1963079401",
					"http://www.roblox.com/asset/?id=4952978082"
				}

			},
			bands = {
				"http://www.roblox.com/asset/?id=4554120874",
				"http://www.roblox.com/asset/?id=4059855083",
				"http://www.roblox.com/asset/?id=298277365",
				"http://www.roblox.com/asset/?id=271399450",
				"http://www.roblox.com/asset/?id=2603766618",
				"http://www.roblox.com/asset/?id=4952983712"
			},
		},
		sorted = {
			"http://www.roblox.com/asset/?id=5365347787",
			"http://www.roblox.com/asset/?id=239715223",

			"http://www.roblox.com/asset/?id=5035514354",
			"http://www.roblox.com/asset/?id=5035513543",

			"http://www.roblox.com/asset/?id=517219890",
			"http://www.roblox.com/asset/?id=517220389",
		}
	},

	reim = {
		random = {
			pants = {
				female = {
					"http://www.roblox.com/asset/?id=9434697684",
					"http://www.roblox.com/asset/?id=9434693818",
					"http://www.roblox.com/asset/?id=9434738457",
					"http://www.roblox.com/asset/?id=9434722469"
				}
			},
		},
		sorted = {
			male = {
				"http://www.roblox.com/asset/?id=9673800668",
				"http://www.roblox.com/asset/?id=9673801212",

				"http://www.roblox.com/asset/?id=9673807189",
				"http://www.roblox.com/asset/?id=9673807972",

				"http://www.roblox.com/asset/?id=9673874682",
				"http://www.roblox.com/asset/?id=9673875110",
			},
		}
	}
}

module.extrawear = {
	--1,5 Immuchakk Headband
	script["Imuchakk v2 (Type1)"],
	script["Imuchakk v2 (Type2)"],
	script["Imuchakk v2 (Type3)"],
	script["Imuchakk v2 (Type4)"],
	script["Imuchakk v2 (Type5)"],

	--6,7 Koy Royalty Cloak
	script.RedKouCloak,
	script.BlackKouCloak
}

module.hats = {
	head = { -- called head for now because it actually easier to group them all as one.
		
		-- 1 - 8 head
		"Feather",
		"Cowl",
		"Fancy Turban",
		"Boring Turban",
		"Head Cover",
		"Mouth Head Cover",
		"Short Covering",
		"Side Headband",
	}
}

module.cloaks = {
	"Fancy Shawl",
	"Flamboyant Scarf",
	"Full Shoulder Cloak",
	"Long Scarf",
	"Long Wrap",
	"Low Bandana",
	"Proper Cloak",
	"Ripped Bandana",
	"Short Shoulder Cloak",
	"Short Wrap",
	"Shoulder Cloak",
	"Shoulder Cloth",
	"Super Torn Cloak",
	"Torn Cloak"
}

module.outfits = {
	desertBasic = {
		shirt = {
			{ id = "rbxassetid://73902351418182",  name = "Long Sleeve" },
			{ id = "rbxassetid://78386065209239",  name = "Vest" },
			{ id = "rbxassetid://126057009576010", name = "Short Sleeve" },
			{ id = "rbxassetid://75749185367229",  name = "Croptop" },
			{ id = "rbxassetid://83154660188892",  name = "Fist Wrapping" },
			{ id = "rbxassetid://113331770157087", name = "Arm Wrapping" },
			{ id = "rbxassetid://118777215103181", name = "Left Arm Wrapping" },
			{ id = "rbxassetid://105315663149351", name = "Right Arm Wrapping" },
			{ id = "rbxassetid://15091718013",     name = "Short Sleeve Rags" },
		},
		pants = {
			{ id = "rbxassetid://103174839005173", name = "Standard"},
			{ id = "rbxassetid://15091719460",     name = "Shoes and Rags"},
			{ id = "rbxassetid://75087301812346",  name = "Barefooted and Rags"},
		}
	}
}


	--[[fana = {
		shirt = {
			"http://www.roblox.com/asset/?id=6422642411",
			"http://www.roblox.com/asset/?id=6536625711",
			"http://www.roblox.com/asset/?id=298277365",
			"http://www.roblox.com/asset/?id=6069375106",
			"http://www.roblox.com/asset/?id=6069382150",
			"http://www.roblox.com/asset/?id=6985240205"
			
		},

		pants = {
			"http://www.roblox.com/asset/?id=11191683322",
			"http://www.roblox.com/asset/?id=6877161467",
			"http://www.roblox.com/asset/?id=6069384640",
			"http://www.roblox.com/asset/?id=6069374592",
			"http://www.roblox.com/asset/?id=4488283880",
			"http://www.roblox.com/asset/?id=6985241978"
		}
	},
	
	immu = {
		shirt = {
			"http://www.roblox.com/asset/?id=6464110188",
			"",
			"http://www.roblox.com/asset/?id=6462839647",
			"",
			"http://www.roblox.com/asset/?id=6462739097",
			"http://www.roblox.com/asset/?id=5901002613"
		},

		pants = {
			"http://www.roblox.com/asset/?id=6460029645",
			"http://www.roblox.com/asset/?id=6463819864",
			"http://www.roblox.com/asset/?id=6463871853",
			"http://www.roblox.com/asset/?id=6463887460",
			"http://www.roblox.com/asset/?id=5900970438",
			"http://www.roblox.com/asset/?id=6460029645"
		}
	},
	
	magician = {
		shirt = {
			"http://www.roblox.com/asset/?id=2511190990",
			"http://www.roblox.com/asset/?id=2511190990",
			"http://www.roblox.com/asset/?id=2511190990",
			"http://www.roblox.com/asset/?id=2511190990",
			"http://www.roblox.com/asset/?id=2511190990",
			"http://www.roblox.com/asset/?id=2511190990",
		},

		pants = {
			"http://www.roblox.com/asset/?id=2511336935",
			"http://www.roblox.com/asset/?id=2511336935",
			"http://www.roblox.com/asset/?id=2511336935",
			"http://www.roblox.com/asset/?id=2511336935",
			"http://www.roblox.com/asset/?id=2511336935",
			"http://www.roblox.com/asset/?id=2511336935"

		}
	},
	
	human = {
		shirt = {
			"http://www.roblox.com/asset/?id=517219890",
			"http://www.roblox.com/asset/?id=1326901773",
			"http://www.roblox.com/asset/?id=2778405426",
			"http://www.roblox.com/asset/?id=12278765931",
			"http://www.roblox.com/asset/?id=8829709797",
			"http://www.roblox.com/asset/?id=331256730"
		},

		pants = {
			"http://www.roblox.com/asset/?id=517220389",
			"http://www.roblox.com/asset/?id=1326902806",
			"http://www.roblox.com/asset/?id=295879590",
			"http://www.roblox.com/asset/?id=12278787782",
			"http://www.roblox.com/asset/?id=8829706878",
			"http://www.roblox.com/asset/?id=331271587"

		}
	},
}]]
	
local itemCodes = {
	["1AA"] = "FeatherHat",
}
	
module.itemLookUp = function(itemSearch)
	return itemCodes[itemSearch]
end

return module
