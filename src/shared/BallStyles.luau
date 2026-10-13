--[[
	Look + animation of each animated ball's parts (premium + earned), and its trail / particles / light.
	Generated from assets/balls/manifest.json by tools/roblox_setup.py (write_ball_styles) - edit the
	manifest and run it again instead of editing this by hand.
	Parts match the model's part names (<Id>_<Part>). Spin axes are in the ball's own
	space (Roblox, Y up). Size = the model's real bounding box at Diameter (studs).
	src/client/BallFx.luau uses this.
	BallStyles[Id] = { Diameter, Size?, Parts = { [Part] = { Color, Material, Transparency, Spin?, Pulse?, Flicker?, Show? } },
	                   Fx = { Trail?, Particles = { ... }, Light? } }
	Flicker = { Hz, Min, Max }: the part's transparency jumps at random between Min and Max
	about Hz times a second (lightning arcs).
	Lite = true: a spinning part that cheap 'lite' balls (extra multiball balls) still show, standing still.
	Show = { Period, From, To, Invert? }: the part is visible only while (time mod Period) is in [From, To),
	or only OUTSIDE that window with Invert = true (e.g. Grinny's creepy face / cute face). All parts
	of one ball share one clock, so their windows line up. Flicker only runs while the part is shown.
	Lite balls don't animate: they keep the Invert parts (always shown) and drop the other Show parts.
	Hidden = true: a part of the model that is never drawn (e.g. a face the ball no longer uses).
]]

return {
	Frostbite = {
		Diameter = 2,
		Size = Vector3.new(1.848, 1.566, 1.812),
		Parts = {
			Core = { Color = Color3.fromRGB(185, 232, 255), Material = Enum.Material.Glass, Transparency = 0.35 },
			Heart = { Color = Color3.fromRGB(90, 185, 255), Material = Enum.Material.Neon, Transparency = 0, Pulse = { Min = 0.86, Max = 1.1, Hz = 0.9 } },
			Spikes = { Color = Color3.fromRGB(215, 242, 255), Material = Enum.Material.Ice, Transparency = 0, Spin = { Axis = Vector3.new(0, -1, 0), Rps = 0.12 } },
			Shards = { Color = Color3.fromRGB(120, 205, 255), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 0.913, 0.407), Rps = 0.32 } },
		},
		Fx = {
			Trail = { Color = Color3.fromRGB(210, 240, 255), Color2 = Color3.fromRGB(110, 190, 255), Lifetime = 0.35, WidthScale = 1 },
			Particles = {
				{ Texture = "sparkle", Color = Color3.fromRGB(225, 245, 255), Rate = 18, Size = { 0.12, 0.28 }, Lifetime = { 0.6, 1.2 }, Speed = { 0.4, 1.4 }, LightEmission = 0.7 },
			},
			Light = { Color = Color3.fromRGB(150, 215, 255), Range = 8, Brightness = 1.2 },
		},
	},
	CyberCore = {
		Diameter = 2,
		Size = Vector3.new(1.866, 1.903, 1.643),
		Parts = {
			Shell = { Color = Color3.fromRGB(38, 44, 56), Material = Enum.Material.Metal, Transparency = 0 },
			Circuits = { Color = Color3.fromRGB(0, 235, 255), Material = Enum.Material.Neon, Transparency = 0 },
			RingA = { Color = Color3.fromRGB(0, 220, 255), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 0.927, 0.375), Rps = 0.45 } },
			RingB = { Color = Color3.fromRGB(165, 175, 192), Material = Enum.Material.Metal, Transparency = 0, Spin = { Axis = Vector3.new(0.47, 0.342, 0.814), Rps = -0.6 } },
		},
		Fx = {
			Trail = { Color = Color3.fromRGB(0, 240, 255), Color2 = Color3.fromRGB(0, 120, 255), Lifetime = 0.3, WidthScale = 0.9 },
			Particles = {
				{ Texture = "sparkle", Color = Color3.fromRGB(120, 245, 255), Rate = 14, Size = { 0.08, 0.18 }, Lifetime = { 0.3, 0.6 }, Speed = { 1, 3 }, LightEmission = 1 },
			},
			Light = { Color = Color3.fromRGB(0, 220, 255), Range = 8, Brightness = 1.5 },
		},
	},
	PlasmaCore = {
		Diameter = 2,
		Size = Vector3.new(1.999, 1.4, 1.427),
		Parts = {
			Core = { Color = Color3.fromRGB(255, 70, 230), Material = Enum.Material.Neon, Transparency = 0, Pulse = { Min = 0.84, Max = 1.12, Hz = 1.6 } },
			Arcs = { Color = Color3.fromRGB(215, 150, 255), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0.195, 0.976, -0.098), Rps = 0.85 } },
			Shell = { Color = Color3.fromRGB(235, 205, 255), Material = Enum.Material.Glass, Transparency = 0.55 },
			RingA = { Color = Color3.fromRGB(255, 80, 235), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 0.743, 0.669), Rps = 1.2 } },
			RingB = { Color = Color3.fromRGB(140, 80, 255), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 0.743, -0.669), Rps = -1.5 } },
		},
		Fx = {
			Trail = { Color = Color3.fromRGB(230, 100, 255), Color2 = Color3.fromRGB(120, 60, 255), Lifetime = 0.4, WidthScale = 1.1 },
			Particles = {
				{ Texture = "sparkle", Color = Color3.fromRGB(255, 150, 255), Rate = 22, Size = { 0.12, 0.3 }, Lifetime = { 0.3, 0.7 }, Speed = { 1, 2.5 }, LightEmission = 1 },
			},
			Light = { Color = Color3.fromRGB(220, 90, 255), Range = 10, Brightness = 2 },
		},
	},
	MagmaHeart = {
		Diameter = 2,
		Size = Vector3.new(1.813, 1.462, 1.879),
		Parts = {
			Shell = { Color = Color3.fromRGB(52, 40, 38), Material = Enum.Material.Basalt, Transparency = 0 },
			Seams = { Color = Color3.fromRGB(255, 150, 25), Material = Enum.Material.Neon, Transparency = 0, Pulse = { Min = 0.96, Max = 1.05, Hz = 1.2 } },
			Core = { Color = Color3.fromRGB(255, 72, 8), Material = Enum.Material.Neon, Transparency = 0 },
			Chunks = { Color = Color3.fromRGB(255, 105, 35), Material = Enum.Material.CrackedLava, Transparency = 0, Spin = { Axis = Vector3.new(0.259, 0.908, -0.33), Rps = 0.4 } },
		},
		Fx = {
			Trail = { Color = Color3.fromRGB(255, 140, 30), Color2 = Color3.fromRGB(200, 40, 10), Lifetime = 0.35, WidthScale = 1 },
			Particles = {
				{ Texture = "fire", Color = Color3.fromRGB(255, 120, 30), Rate = 20, Size = { 0.25, 0.6 }, Lifetime = { 0.3, 0.6 }, Speed = { 0.5, 1.5 }, LightEmission = 1 },
				{ Texture = "smoke", Color = Color3.fromRGB(70, 60, 60), Rate = 6, Size = { 0.4, 1 }, Lifetime = { 0.6, 1.2 }, Speed = { 0.3, 0.8 }, LightEmission = 0 },
			},
			Light = { Color = Color3.fromRGB(255, 120, 30), Range = 10, Brightness = 2 },
		},
	},
	BlackHole = {
		Diameter = 2,
		Size = Vector3.new(1.988, 1.195, 1.925),
		Parts = {
			Core = { Color = Color3.fromRGB(6, 4, 12), Material = Enum.Material.SmoothPlastic, Transparency = 0 },
			Disk = { Color = Color3.fromRGB(255, 125, 35), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 0.961, 0.276), Rps = 0.5 } },
			DiskInner = { Color = Color3.fromRGB(255, 238, 195), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 0.961, 0.276), Rps = 0.95 } },
			Lens = { Color = Color3.fromRGB(150, 85, 255), Material = Enum.Material.ForceField, Transparency = 0, Pulse = { Min = 0.96, Max = 1.06, Hz = 0.6 } },
			Debris = { Color = Color3.fromRGB(205, 175, 255), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 0.961, 0.276), Rps = 0.7 } },
		},
		Fx = {
			Trail = { Color = Color3.fromRGB(110, 40, 190), Color2 = Color3.fromRGB(25, 0, 50), Lifetime = 0.45, WidthScale = 1.1 },
			Particles = {
				{ Texture = "sparkle", Color = Color3.fromRGB(200, 150, 255), Rate = 20, Size = { 0.08, 0.2 }, Lifetime = { 0.4, 0.8 }, Speed = { -1.5, -0.5 }, LightEmission = 0.8 },
			},
			Light = { Color = Color3.fromRGB(170, 80, 255), Range = 9, Brightness = 1.5 },
		},
	},
	Supernova = {
		Diameter = 2,
		Size = Vector3.new(1.775, 1.639, 1.732),
		Parts = {
			Core = { Color = Color3.fromRGB(255, 246, 215), Material = Enum.Material.Neon, Transparency = 0, Pulse = { Min = 0.88, Max = 1.14, Hz = 1.5 } },
			Corona = { Color = Color3.fromRGB(255, 150, 20), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 1, 0), Rps = 0.22 } },
			Flares = { Color = Color3.fromRGB(255, 228, 150), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0.282, 0.941, 0.188), Rps = -0.15 }, Pulse = { Min = 0.9, Max = 1.06, Hz = 2.2 } },
			RingA = { Color = Color3.fromRGB(255, 205, 70), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 0.951, 0.309), Rps = 0.55 } },
			RingB = { Color = Color3.fromRGB(255, 135, 35), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0.765, 0.469, 0.442), Rps = -0.75 } },
			RingC = { Color = Color3.fromRGB(255, 238, 170), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(-0.765, 0.469, 0.442), Rps = 0.95 } },
		},
		Fx = {
			Trail = { Color = Color3.fromRGB(255, 200, 60), Color2 = Color3.fromRGB(255, 255, 235), Lifetime = 0.5, WidthScale = 1.3 },
			Particles = {
				{ Texture = "sparkle", Color = Color3.fromRGB(255, 240, 180), Rate = 40, Size = { 0.15, 0.45 }, Lifetime = { 0.3, 0.8 }, Speed = { 1.5, 4 }, LightEmission = 1 },
				{ Texture = "fire", Color = Color3.fromRGB(255, 150, 40), Rate = 25, Size = { 0.3, 0.8 }, Lifetime = { 0.25, 0.5 }, Speed = { 0.5, 1.5 }, LightEmission = 1 },
			},
			Light = { Color = Color3.fromRGB(255, 200, 110), Range = 14, Brightness = 3 },
		},
	},
	Infinity = {
		Diameter = 2,
		Size = Vector3.new(2, 1.535, 1.998),
		Parts = {
			Core = { Color = Color3.fromRGB(5, 3, 12), Material = Enum.Material.SmoothPlastic, Transparency = 0 },
			ArmsA = { Color = Color3.fromRGB(112, 100, 255), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 0.215, 0.977), Rps = 0.1 }, Lite = true },
			ArmsB = { Color = Color3.fromRGB(255, 92, 214), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 0.215, 0.977), Rps = 0.1 }, Lite = true },
			Stars = { Color = Color3.fromRGB(240, 232, 255), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 0.215, 0.977), Rps = 0.1 }, Lite = true },
			Shell = { Color = Color3.fromRGB(70, 44, 140), Material = Enum.Material.Glass, Transparency = 0.55 },
			RingA = { Color = Color3.fromRGB(255, 196, 78), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0, 1, 0), Rps = 0.28 }, Lite = true },
			RingB = { Color = Color3.fromRGB(255, 236, 186), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0.559, 0.829, 0), Rps = -0.36 } },
			BoltsA = { Color = Color3.fromRGB(80, 225, 255), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(0.282, 0.941, -0.188), Rps = 1.4 }, Flicker = { Hz = 9, Min = 0, Max = 1 } },
			BoltsB = { Color = Color3.fromRGB(190, 245, 255), Material = Enum.Material.Neon, Transparency = 0, Spin = { Axis = Vector3.new(-0.337, 0.842, -0.421), Rps = -1.9 }, Flicker = { Hz = 13, Min = 0, Max = 1 } },
		},
		Fx = {
			Trail = { Color = Color3.fromRGB(120, 60, 240), Color2 = Color3.fromRGB(255, 228, 150), Lifetime = 0.5, WidthScale = 1.25 },
			Particles = {
				{ Texture = "sparkle", Color = Color3.fromRGB(255, 240, 205), Rate = 30, Size = { 0.12, 0.38 }, Lifetime = { 0.4, 1 }, Speed = { 0.6, 2.2 }, LightEmission = 1 },
				{ Texture = "sparkle", Color = Color3.fromRGB(150, 225, 255), Rate = 16, Size = { 0.06, 0.16 }, Lifetime = { 0.12, 0.3 }, Speed = { 2.5, 5 }, LightEmission = 1 },
			},
			Light = { Color = Color3.fromRGB(165, 110, 255), Range = 12, Brightness = 2.4 },
		},
	},
	Smashbot = {
		Diameter = 2,
		Size = Vector3.new(1.957, 1.949, 1.763),
		Parts = {
			Core = { Color = Color3.fromRGB(255, 150, 32), Material = Enum.Material.Neon, Transparency = 0 },
			Plates = { Color = Color3.fromRGB(86, 94, 110), Material = Enum.Material.Metal, Transparency = 0, Pulse = { Min = 1, Max = 1.15, Hz = 0.5 } },
			Rivets = { Color = Color3.fromRGB(196, 202, 214), Material = Enum.Material.Metal, Transparency = 0, Pulse = { Min = 1, Max = 1.15, Hz = 0.5 } },
			Stripes = { Color = Color3.fromRGB(255, 118, 12), Material = Enum.Material.SmoothPlastic, Transparency = 0, Pulse = { Min = 1, Max = 1.15, Hz = 0.5 } },
			Socket = { Color = Color3.fromRGB(30, 33, 41), Material = Enum.Material.Metal, Transparency = 0 },
			Lens = { Color = Color3.fromRGB(35, 226, 255), Material = Enum.Material.Neon, Transparency = 0, Pulse = { Min = 0.975, Max = 1.03, Hz = 1.1 } },
			Pupil = { Color = Color3.fromRGB(225, 255, 255), Material = Enum.Material.Neon, Transparency = 0, Pulse = { Min = 0.975, Max = 1.03, Hz = 1.1 } },
			Gear = { Color = Color3.fromRGB(255, 128, 22), Material = Enum.Material.Metal, Transparency = 0, Spin = { Axis = Vector3.new(0.237, 0.208, 0.949), Rps = 0.3 } },
		},
		Fx = {
			Trail = { Color = Color3.fromRGB(255, 140, 30), Color2 = Color3.fromRGB(40, 220, 255), Lifetime = 0.35, WidthScale = 1 },
			Particles = {
				{ Texture = "sparkle", Color = Color3.fromRGB(255, 170, 60), Rate = 26, Size = { 0.08, 0.2 }, Lifetime = { 0.2, 0.45 }, Speed = { 2.5, 6 }, LightEmission = 1 },
				{ Texture = "sparkle", Color = Color3.fromRGB(120, 235, 255), Rate = 10, Size = { 0.1, 0.24 }, Lifetime = { 0.3, 0.6 }, Speed = { 0.4, 1.2 }, LightEmission = 1 },
			},
			Light = { Color = Color3.fromRGB(80, 220, 255), Range = 10, Brightness = 2 },
		},
	},
	Grinny = {
		Diameter = 2,
		Size = Vector3.new(1.762, 1.558, 1.607),
		Parts = {
			Seams = { Color = Color3.fromRGB(168, 96, 14), Material = Enum.Material.SmoothPlastic, Transparency = 0 },
			Panels = { Color = Color3.fromRGB(255, 194, 28), Material = Enum.Material.SmoothPlastic, Transparency = 0 },
			Net = { Color = Color3.fromRGB(250, 250, 244), Material = Enum.Material.SmoothPlastic, Transparency = 0 },
			CuteEyes = { Color = Color3.fromRGB(22, 16, 12), Material = Enum.Material.SmoothPlastic, Transparency = 0, Hidden = true },
			CuteShine = { Color = Color3.fromRGB(255, 255, 255), Material = Enum.Material.Neon, Transparency = 0, Hidden = true },
			CuteSmile = { Color = Color3.fromRGB(44, 22, 10), Material = Enum.Material.SmoothPlastic, Transparency = 0, Hidden = true },
			Blush = { Color = Color3.fromRGB(255, 128, 72), Material = Enum.Material.SmoothPlastic, Transparency = 0.25, Hidden = true },
			GrinEyes = { Color = Color3.fromRGB(14, 10, 8), Material = Enum.Material.SmoothPlastic, Transparency = 0 },
			GrinShine = { Color = Color3.fromRGB(255, 255, 255), Material = Enum.Material.Neon, Transparency = 0 },
			Mouth = { Color = Color3.fromRGB(26, 12, 9), Material = Enum.Material.SmoothPlastic, Transparency = 0 },
			Teeth = { Color = Color3.fromRGB(252, 249, 236), Material = Enum.Material.SmoothPlastic, Transparency = 0 },
			Ghost = { Color = Color3.fromRGB(40, 225, 255), Material = Enum.Material.Neon, Transparency = 0, Flicker = { Hz = 20, Min = 0, Max = 1 }, Show = { Period = 4, From = 2.9, To = 3.3 } },
			GlitchBars = { Color = Color3.fromRGB(215, 250, 255), Material = Enum.Material.Neon, Transparency = 0, Flicker = { Hz = 26, Min = 0, Max = 1 }, Show = { Period = 4, From = 2.82, To = 3.08 } },
		},
		Fx = {
			Trail = { Color = Color3.fromRGB(255, 214, 60), Color2 = Color3.fromRGB(70, 34, 8), Lifetime = 0.4, WidthScale = 1.1 },
			Particles = {
				{ Texture = "sparkle", Color = Color3.fromRGB(255, 226, 90), Rate = 24, Size = { 0.1, 0.3 }, Lifetime = { 0.4, 0.9 }, Speed = { 0.6, 2 }, LightEmission = 1 },
				{ Texture = "sparkle", Color = Color3.fromRGB(255, 255, 245), Rate = 8, Size = { 0.05, 0.12 }, Lifetime = { 0.5, 1.1 }, Speed = { 0.3, 1 }, LightEmission = 0.3 },
			},
			Light = { Color = Color3.fromRGB(255, 200, 80), Range = 10, Brightness = 1.8 },
		},
	},
}
