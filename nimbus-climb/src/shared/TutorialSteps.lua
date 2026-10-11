-- TutorialSteps: the new-player tutorial, told by Nimbus the Cloudy Dragon (ARCHITECTURE_V3.md section 4 and the
-- Phase 2 "Tutorial" paragraph). Data only: TutorialService (server) walks a player through these steps in order and
-- TutorialController (client) shows them in the side panel.
--
-- Chapters. Saved progress is the step INDEX (Profile.Tutorial.Step), so steps are only ever APPENDED: chapter 1
-- (steps 1-9, the Phase 1 basics) keeps its indices, chapter 2 (the tycoon home, Phase 2) follows, Phase 3 appends
-- the arena. A player who finished an earlier chapter resumes at the first step of the next one when it ships
-- (TutorialService: a stored Done tutorial whose Step points into a later chapter carries on from there).
--
-- Step fields
--   Id          unique step id
--   Chapter     1 (basics) or 2 (home); defaults to 1
--   ChapterEnd  true on the last step of a chapter: completing it pays the chapter's reward once
--               (chapter 1: Config.Tutorial.FinishReward; chapter 2: TutorialService's home reward)
--   Title       short headline shown above the text
--   Text        what Nimbus says (short, friendly). Placeholders filled in by TutorialService:
--               {GiftTokens} = Config.Tutorial.GiftTokens, {FinishTokens} = Config.Tutorial.FinishReward.Tokens
--   Target      nil, or where the guide arrow points:
--                 { Kind = "Spot" }                     the player's own home plot (SpotIndex attribute)
--                 { Kind = "Spot", Gate = true }        the gate of the plot the player should claim: their claimed
--                                                       plot, else their last plot when free, else the nearest free
--                                                       plot (SpotService.SuggestSpot)
--                 { Kind = "Spot", Pad = "Press1" }     a buy pad on the player's own plot (Pad_<StationId>)
--                     + Path = true                     ...or the next pad on the way to it (its prerequisites)
--                     + Station = "Collector"           ...or that station once it is built
--                 { Kind = "Spot", Station = "Kitchen", Food = true }   the Kitchen while the player has no food,
--                                                       then the Pets menu button (feed a pet)
--                 { Kind = "Shop" }                     the roulette machines (Roulette_<first roulette id>)
--                 { Kind = "Roulette", Id = "Cloud" }   model Roulette_<Id> under workspace.NimbusLobby
--                 { Kind = "Portal", Id = "Easy" }      model Portal_<Id> under workspace.NimbusLobby
--                 { Kind = "Menu", Id = "Pets" }        the menu button MenuButton_<Id>
--               Label (optional) names the target on the floating sign above the arrow. TutorialService resolves
--               the home targets on the server and sends Kind "Spot" + Position (or Kind "Menu") to the client.
--   CompleteOn  "Next"         the player presses Next (client event)
--               "NearSpot"     within 14 studs of the player's own SpotInfo.Center (server poll; kept for old data)
--               "Claimed"      the player owns a home plot (claimed with E at a gate)
--               "Built"        the home has the station `Station` at level 1 or more
--               "Collected"    the player banked the Collector's Cash (the Collector emptied into the balance)
--               "Fed"          the player fed a pet (PetCareService.Fed: the Pets panel or the Kitchen's bowl)
--               "ShopOpened"   the Shop window opened (client event)
--               "Rolled"       a roulette spin succeeded (PetService.Rolled)
--               "Equipped"     the player equips a pet / opens Pets with a pet equipped
--               "IndexOpened"  the Pet Index window opened (client event)
--               "MatchStarted" the player's InMatch attribute turned true
--               "MatchEnded"   the player's InMatch attribute turned false again
--   Station     the station id a "Built" step waits for
--   Gift        true: entering this step grants Config.Tutorial.GiftTokens once (Profile.Tutorial.Gifted)
--   Hint        short objective line shown under the text while the step waits for an action (TutorialService
--               may send a more precise one, e.g. the next pad on the way to the Kitchen)
--   Button      label of the Next button (CompleteOn = "Next" only)
--
-- Plain Lua 5.1-compatible syntax only.

local TutorialSteps = {}

TutorialSteps.Guide = {
	Name = "Nimbus",
	Title = "the Cloudy Dragon",
	PetId = "cloudy_dragon", -- PetCatalog id of the portrait in the side panel
}

TutorialSteps.Steps = {
	----------------------------------------------------------------------------------------------- chapter 1: basics
	{
		Id = "welcome",
		Chapter = 1,
		Title = "Hi there, climber!",
		Text = "I'm Nimbus, the Cloudy Dragon! Welcome to my sky village. Stick with me and I'll show you around. It's quick, promise!",
		Target = nil,
		CompleteOn = "Next",
		Button = "Let's go!",
	},
	{
		-- (Phase 2: homes are claimed with E at their gate, so this step now leads to a free gate)
		Id = "home",
		Chapter = 1,
		Title = "Your Home Plot",
		Text = "Every climber can have a home plot on the big ring! Follow my golden arrow to a free gate and press E to make it yours.",
		Target = { Kind = "Spot", Gate = true, Label = "Free home" },
		CompleteOn = "Claimed",
		Hint = "Press E at a free gate",
	},
	{
		Id = "shop",
		Chapter = 1,
		Title = "The Cloud Shop",
		Text = "Next stop: the Cloud Shop! Follow the arrow to the roulette machines and open one. The Shop button works too!",
		Target = { Kind = "Shop", Label = "Cloud Shop" },
		CompleteOn = "ShopOpened",
		Hint = "Open the shop",
	},
	{
		Id = "spin",
		Chapter = 1,
		Title = "Your First Pet",
		Text = "Here are {GiftTokens} Cloud Tokens, my treat! Spin the Cloud Roulette to hatch your very first pet buddy.",
		Target = { Kind = "Roulette", Id = "Cloud", Label = "Cloud Roulette" },
		CompleteOn = "Rolled",
		Gift = true,
		Hint = "Spin a roulette",
	},
	{
		Id = "equip",
		Chapter = 1,
		Title = "Pick a Buddy",
		Text = "Aww, a new friend! Open Pets and equip your buddy so it flies right beside you. Pets give handy perks!",
		Target = { Kind = "Menu", Id = "Pets" },
		CompleteOn = "Equipped",
		Hint = "Tap the glowing Pets button",
	},
	{
		Id = "index",
		Chapter = 1,
		Title = "The Pet Index",
		Text = "Every pet you find lands in the Pet Index. Take a peek! Collect a whole rarity group for a big reward.",
		Target = { Kind = "Menu", Id = "Index" },
		CompleteOn = "IndexOpened",
		Hint = "Tap the glowing Index button",
	},
	{
		Id = "portal",
		Chapter = 1,
		Title = "Time to Climb!",
		Text = "Now the fun part! Step into the Easy portal and wait for the countdown. Friends can hop in with you.",
		Target = { Kind = "Portal", Id = "Easy", Label = "Easy Portal" },
		CompleteOn = "MatchStarted",
		Hint = "Stand in the Easy portal",
	},
	{
		Id = "finish",
		Chapter = 1,
		Title = "Up, Up and Away!",
		Text = "Hop from cloud to cloud, grab the shiny tokens and reach the finish. Checkpoints keep your progress. You've got this!",
		Target = nil,
		CompleteOn = "MatchEnded",
		Hint = "Reach the finish",
	},
	{
		Id = "done",
		Chapter = 1,
		ChapterEnd = true,
		Title = "You're a Natural!",
		Text = "That's the basics, climber! Here are {FinishTokens} Cloud Tokens to celebrate. Next up: your very own home!",
		Target = nil,
		CompleteOn = "Next",
		Button = "Collect!",
	},
	------------------------------------------------------------------------------------- chapter 2: the tycoon home
	{
		Id = "claim",
		Chapter = 2,
		Title = "Claim Your Home",
		Text = "Homes are the heart of Nimbus Village! Walk up to a free gate and press E. The plot is yours for as long as you play.",
		Target = { Kind = "Spot", Gate = true, Label = "Free home" },
		CompleteOn = "Claimed",
		Hint = "Press E at a free gate",
	},
	{
		Id = "press",
		Chapter = 2,
		Title = "Your First Cloud Press",
		Text = "Every great home starts with a Cloud Press! Stand on its glowing pad and press E to build it. The first one is free!",
		Target = { Kind = "Spot", Pad = "Press1", Label = "Cloud Press pad" },
		CompleteOn = "Built",
		Station = "Press1",
		Hint = "Press E on the Cloud Press pad",
	},
	{
		Id = "collect",
		Chapter = 2,
		Title = "Bank Your Cash",
		Text = "Your press puffs cloud blocks into the Collector, and they turn into Cash! Build the Collector (it's free), then step on it to bank your Cash.",
		Target = { Kind = "Spot", Pad = "Collector", Station = "Collector", Label = "Collector" },
		CompleteOn = "Collected",
		Hint = "Step on the Collector",
	},
	{
		Id = "kitchen",
		Chapter = 2,
		Title = "Build the Kitchen",
		Text = "Spend your Cash on upgrades: new pads pop up as your home grows. Follow my arrow from pad to pad until you can build the Kitchen!",
		Target = { Kind = "Spot", Pad = "Kitchen", Path = true, Label = "Kitchen pad" },
		CompleteOn = "Built",
		Station = "Kitchen",
		Hint = "Build the Kitchen",
	},
	{
		Id = "feed",
		Chapter = 2,
		ChapterEnd = true,
		Title = "Snack Time!",
		Text = "Cook a Snack at your Kitchen (press E at the counter), then open Pets and press Feed. Fed pets level up and grow stronger!",
		Target = { Kind = "Spot", Station = "Kitchen", Food = true, Label = "Kitchen" },
		CompleteOn = "Fed",
		Hint = "Cook a Snack, then feed a pet",
	},
}

-- Id -> index lookup and the first step of every chapter (data, built once).
TutorialSteps.IndexOf = {}
TutorialSteps.ChapterStart = {}
for index, step in ipairs(TutorialSteps.Steps) do
	TutorialSteps.IndexOf[step.Id] = index
	local chapter = step.Chapter or 1
	if not TutorialSteps.ChapterStart[chapter] then
		TutorialSteps.ChapterStart[chapter] = index
	end
end

return TutorialSteps
