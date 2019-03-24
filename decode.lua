
local file = io.stdin

local function readShort(file)
	local data = file:read(2)
	if not data then return end
	local l, h = data:byte(1, 2)
	return h * 256 + l
end

local function exec(cmd)
	local proc = io.popen(cmd, "r")
	local res = proc:read("*a"):gsub("\n$", "")
	proc:close()
	return res
end

local function time()
	-- obviously the best way to get the current time, even has a fallback for BSD date not supporting %N
	return tonumber((exec("date +%s.%N"):gsub("N$", ""))) or 0
end

local function makeSlider(size)
	local window = {}
	return function(data)
		for i = size - 1, 1, -1 do
			window[i + 1] = window[i]
		end
		window[1] = data
		return window
	end
end

local function classify(window, thresh, count)
	for _, data in ipairs(window) do
		if data > thresh then
			count = count - 1
		end
	end
	return count <= 0 and "X" or "-"
end

local function bitWindowToNum(window, bits)
	local acc = 0
	for i = 1, bits do
		acc = acc + (window[i] or 0) * 2^(i - 1)
	end
	return acc
end

local function bitWindowToByte(window)
	return bitWindowToNum(window, 8)
end

local function bitWindowToNibble(window)
	return bitWindowToNum(window, 4)
end

local slider = makeSlider(17)
local bits = makeSlider(8)
local symbolState = "space"
local counter = 0


local function getMajority(a, b, c, d, e)
	if a == b and a == c -- abc
	or a == c and a == d -- acd
	or a == d and a == e -- ade
	or a == b and a == d -- abd
	or a == b and a == e -- abe
	or a == c and a == e -- ace
	then
		return a
	end
	if b == c and b == d -- bcd
	or b == c and b == e -- bce
	or b == c and b == e -- bde
	then
		return b
	end
	if c == d and c == e then -- cde
		return c
	end
	
end

local function putval(path, key, value)
	print(("PUTVAL \"%s/%s/%s\" interval=-1 %d:%d"):format(exec("hostname -s"):gsub("%s", ""), path, key, time(), value))
	io.stdout:flush()
end

local datagrams = {
	makeSlider(5),
	makeSlider(5),
	makeSlider(5),
	makeSlider(5)
}

local function handleDatagram(temp, humidity, channel)
	local window = datagrams[channel]({ temp = temp, humidity = humidity, time = time() })
	for i = #window, 2, -1 do
		if window[1].time - window[i].time > 2 then -- data rate is around 5 datagrams per second
			window[i] = nil
		end
	end
	local d1, d2, d3, d4, d5 = window[1], window[2], window[3], window[4], window[5]
	local temp = getMajority(d1.temp, d2 and d2.temp, d3 and d3.temp, d4 and d4.temp, d5 and d5.temp)
	local humidity = getMajority(d1.humidity, d2 and d2.humidity, d3 and d3.humidity, d4 and d4.humidity, d5 and d5.humidity)
	if temp then
		putval("digoo_r8s", "temperature-" .. channel, temp)
	end
	if humidity then
		putval("digoo_r8s", "humidity-" .. channel, humidity)
	end
end

local bitState = "idle"
local bitCounter = 0
local temp1, temp2, channel
local function handleBit(window)
	local byte = bitWindowToByte(window)
	local nibble = bitWindowToNibble(window)
	if bitState == "idle" then
		if nibble == 9 then
			bitState = "unknown1"
			bitCounter = 0
		end
	elseif bitState == "unknown1" then
		bitCounter = bitCounter + 1
		if bitCounter == 10 then
			bitState = "channel"
			bitCounter = 0
		end
	elseif bitState == "channel" then
		bitCounter = bitCounter + 1
		if bitCounter == 2 then
			bitState = "temp1"
			bitCounter = 0
			channel = bitWindowToNum(window, 2) + 1
		end
	elseif bitState == "temp1" then
		bitCounter = bitCounter + 1
		if bitCounter == 4 then
			temp1 = nibble
			bitState = "temp2"
			bitCounter = 0
		end
	elseif bitState == "temp2" then
		bitCounter = bitCounter + 1
		if bitCounter == 8 then
			temp2 = temp1 * 256 + byte
			if temp2 >= 2^11 then
				temp2 = temp2 - 2^12
			end
			bitState = "humidity"
			bitCounter = 0
		end
	elseif bitState == "humidity" then
		bitCounter = bitCounter + 1
		if bitCounter == 8 then
			bitState = "trailer"
			bitCounter = 0
			handleDatagram(temp2, byte, channel)
		end
	elseif bitState == "trailer" then
		bitCounter = bitCounter + 1
		if bitCounter == 2 then
			bitState = "idle"
			bitCounter = 0
		end
	end
end

local function resetState()
	bitState = "idle"
	bitCounter = 0
	local bitWindow = bits(0)
	for i = 1, #bitWindow do
		bitWindow[i] = nil
	end
end

local sampleCounter = 0
while true do
	short = readShort(file)
	if not short then break end
	local window = slider(short)
	local symbol = classify(window, 2000, 10)
	if symbolState == "space" then
		if symbol == "-" then
			counter = counter + 1
			if counter > 3000 then
				resetState()
				counter = 0
			end
		else
			if counter > 80 and counter < 300 then
				--io.stdout:write(1) io.stdout:flush()
				handleBit(bits(1))
			elseif counter > 30 and counter < 80 then
				--io.stdout:write(0) io.stdout:flush()
				handleBit(bits(0))
			end
			counter = 0
			symbolState = "mark"
		end
	elseif symbolState == "mark" then
		if symbol == "X" then
			counter = counter + 1
		else
			counter = 0
			symbolState = "space"
		end
	end
end


