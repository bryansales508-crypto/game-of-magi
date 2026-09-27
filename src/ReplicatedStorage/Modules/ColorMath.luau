--!strict
--!optimize 2
--!native
--|bruh

--[[ ColorMath : Crazyblox 2025

	ABOUT:
An easy-to-use math extension of RBX Color3.
Color3 doesn't support math, and stores its values as 0-1 sRGB floats.
The sRGB color space splits dark and bright values between a linear scale [straight] and a gamma curve.
sRGB originated in 1996, allocating human-noticeable color differences to an 8-bit integer.
Due to this, sRGB needs converting to Linear RGB [AKA lRGB] so that we can do math.

	SETUP:
As this module is Color3-only, replacing the Color3 global is optimal for readability.
The below line gives you auto-complete where you would need it most for these functions.
local Color3 = require(path.to.module)

	API:
API is minimal, accepting and returning standard Color3 userdata.
Color3's are converted from sRGB, calculated as lRGB, and converted back to sRGB.
This can be costly in heavy loops, but this is designed for ease-of-use, not speed.
Long-term compatibility is ensured by preventing below API's being overrided by Roblox.
Colorspace conversions are included for more granular operation [eg. Color3:Lerp()]

Math [sRGB input only]:
ColorMath.add( Color3, ...Color3 ): Color3
ColorMath.sub( Color3, ...Color3 ): Color3
ColorMath.mul( Color3, ...Color3 ): Color3
ColorMath.div( Color3, ...Color3 ): Color3
ColorMath.idiv( Color3, ...Color3 ): Color3

Color Space:
ColorMath.sRGB_To_lRGB( ...Color3 ): ...Color3
ColorMath.lRGB_To_sRGB( ...Color3 ): ...Color3
]]

local ColorMath = {
	--Adds given Color3's in order
	add = function( Start: Color3, ...: Color3 ): Color3
		--Start with initial color
		local C: vector = vector.create(
			Start.R <= 0.04045 and Start.R * 0.07739938080495357 or ( ( Start.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.G <= 0.04045 and Start.G * 0.07739938080495357 or ( ( Start.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.B <= 0.04045 and Start.B * 0.07739938080495357 or ( ( Start.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
		)
		--Iterate through remainder of colors
		for _, Color: Color3 in {...} do 
			C += vector.create(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			)
		end
		return Color3.new(
			C.x <= 0.0031308 and C.x * 12.92 or 1.055 * ( C.x ^ 0.4166666666666667 ) - 0.055,
			C.y <= 0.0031308 and C.y * 12.92 or 1.055 * ( C.y ^ 0.4166666666666667 ) - 0.055,
			C.z <= 0.0031308 and C.z * 12.92 or 1.055 * ( C.z ^ 0.4166666666666667 ) - 0.055
		)
	end,
	
	--Subtracts given Color3's in order
	sub = function( Start: Color3, ...: Color3 ): Color3
		--Start with initial color
		local C: vector = vector.create(
			Start.R <= 0.04045 and Start.R * 0.07739938080495357 or ( ( Start.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.G <= 0.04045 and Start.G * 0.07739938080495357 or ( ( Start.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.B <= 0.04045 and Start.B * 0.07739938080495357 or ( ( Start.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
		)
		--Iterate through remainder of colors
		for _, Color: Color3 in {...} do
			C -= vector.create(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			)
		end
		return Color3.new(
			C.x <= 0.0031308 and C.x * 12.92 or 1.055 * ( C.x ^ 0.4166666666666667 ) - 0.055,
			C.y <= 0.0031308 and C.y * 12.92 or 1.055 * ( C.y ^ 0.4166666666666667 ) - 0.055,
			C.z <= 0.0031308 and C.z * 12.92 or 1.055 * ( C.z ^ 0.4166666666666667 ) - 0.055
		)
	end,
	
	--Multiplies given Color3's in order
	mul = function( Start: Color3, ...: Color3 ): Color3
		--Start with initial color
		local C: vector = vector.create(
			Start.R <= 0.04045 and Start.R * 0.07739938080495357 or ( ( Start.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.G <= 0.04045 and Start.G * 0.07739938080495357 or ( ( Start.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.B <= 0.04045 and Start.B * 0.07739938080495357 or ( ( Start.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
		)
		--Iterate through remainder of colors
		for _, Color: Color3 in {...} do
			C *= vector.create(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			)
		end
		return Color3.new(
			C.x <= 0.0031308 and C.x * 12.92 or 1.055 * ( C.x ^ 0.4166666666666667 ) - 0.055,
			C.y <= 0.0031308 and C.y * 12.92 or 1.055 * ( C.y ^ 0.4166666666666667 ) - 0.055,
			C.z <= 0.0031308 and C.z * 12.92 or 1.055 * ( C.z ^ 0.4166666666666667 ) - 0.055
		)
	end,
	
	--Divides given Color3's in order
	div = function( Start: Color3, ...: Color3 ): Color3
		--Start with initial color
		local C: vector = vector.create(
			Start.R <= 0.04045 and Start.R * 0.07739938080495357 or ( ( Start.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.G <= 0.04045 and Start.G * 0.07739938080495357 or ( ( Start.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.B <= 0.04045 and Start.B * 0.07739938080495357 or ( ( Start.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
		)
		--Iterate through remainder of colors
		for _, Color: Color3 in {...} do
			C /= vector.create(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			)
		end
		return Color3.new(
			C.x <= 0.0031308 and C.x * 12.92 or 1.055 * ( C.x ^ 0.4166666666666667 ) - 0.055,
			C.y <= 0.0031308 and C.y * 12.92 or 1.055 * ( C.y ^ 0.4166666666666667 ) - 0.055,
			C.z <= 0.0031308 and C.z * 12.92 or 1.055 * ( C.z ^ 0.4166666666666667 ) - 0.055
		)
	end,
	
	--Floor-divides given Color3's in order
	idiv = function( Start: Color3, ...: Color3 ): Color3
		--Start with initial color
		local C: vector = vector.create(
			Start.R <= 0.04045 and Start.R * 0.07739938080495357 or ( ( Start.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.G <= 0.04045 and Start.G * 0.07739938080495357 or ( ( Start.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.B <= 0.04045 and Start.B * 0.07739938080495357 or ( ( Start.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
		)
		--Iterate through remainder of colors
		for _, Color: Color3 in {...} do
			C //= vector.create(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			)
		end
		return Color3.new(
			C.x <= 0.0031308 and C.x * 12.92 or 1.055 * ( C.x ^ 0.4166666666666667 ) - 0.055,
			C.y <= 0.0031308 and C.y * 12.92 or 1.055 * ( C.y ^ 0.4166666666666667 ) - 0.055,
			C.z <= 0.0031308 and C.z * 12.92 or 1.055 * ( C.z ^ 0.4166666666666667 ) - 0.055
		)
	end,
	
	sRGB_To_lRGB = function( ...: Color3 ): ...Color3
		local C: {Color3} = {}
		for _, Color: Color3 in {...} do
			table.insert( C, Color3.new(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			) )
		end
		return table.unpack( C )
	end,
	
	lRGB_To_sRGB = function( ...: Color3 ): ...Color3
		local C: {Color3} = {}
		for _, Color: Color3 in {...} do
			table.insert( C, Color3.new(
				Color.R <= 0.0031308 and Color.R * 12.92 or 1.055 * ( Color.R ^ 0.4166666666666667 ) - 0.055,
				Color.G <= 0.0031308 and Color.G * 12.92 or 1.055 * ( Color.G ^ 0.4166666666666667 ) - 0.055,
				Color.B <= 0.0031308 and Color.B * 12.92 or 1.055 * ( Color.B ^ 0.4166666666666667 ) - 0.055
				) )
		end
		return table.unpack( C )
	end
}
for name, method in Color3 do
	if not ColorMath[ name ] then
		ColorMath[ name ] = method
	end
end
return table.freeze( ColorMath )