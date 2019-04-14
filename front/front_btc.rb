# Copyright (c) 2018-2019 Zerocracy, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'sibit'
require 'syncem'
require 'glogin'
require_relative '../objects/assets'
require_relative '../objects/coinbase'
require_relative '../objects/referrals'
require_relative '../objects/user_error'

set :codec, GLogin::Codec.new(settings.config['pkey_secret'])

def assets(log: settings.log)
  SyncEm.new(
    WTS::Assets.new(
      settings.pgsql,
      log: log,
      codec: settings.codec,
      sibit: Sibit.new(log: log)
    )
  )
end

def coinbase(log: settings.log)
  if settings.config['coinbase']
    SyncEm.new(
      WTS::Coinbase.new(
        settings.config['coinbase']['key'],
        settings.config['coinbase']['secret'],
        settings.config['coinbase']['account'],
        log: log
      )
    )
  else
    WTS::Coinbase::Fake.new
  end
end

def referrals(log: settings.log)
  WTS::Referrals.new(settings.pgsql, log: log)
end

settings.daemons.start('btc-monitor') do
  seen = settings.toggles.get('latestblock', '')
  seen = assets.monitor(seen) do |address, hash, satoshi|
    bitcoin = (satoshi.to_f / 100_000_000).round(8)
    if assets.owned?(address)
      zld = Zold::Amount.new(zld: bitcoin / rate)
      bnf = user(assets.owner(address))
      boss = user(settings.config['exchange']['login'])
      settings.log.info("Accepting #{bitcoin} bitcoins from #{address}...")
      ops(boss, log: settings.log).pull
      ops(boss, log: settings.log).pay(
        settings.config['exchange']['keygap'],
        bnf.item.id, zld,
        "BTC exchange of #{bitcoin} at #{hash}, rate is #{rate}"
      )
      if referrals.exists?(bnf.login)
        fee = settings.toggles.get('referral-fee', '0.04').to_f
        ops(boss, log: settings.log).pay(
          settings.config['exchange']['keygap'],
          user(referrals.ref(bnf.login)).item.id,
          zld * fee, "#{(fee * 100).round(2)} referral fee for BTC exchange"
        )
      end
      ops(boss, log: settings.log).push
      settings.telepost.spam(
        "In: #{format('%.06f', bitcoin)} BTC",
        "[exchanged](https://blog.zold.io/2018/12/09/btc-to-zld.html) to **#{zld}**",
        "by #{title_md(bnf)}",
        "in [#{hash}](https://www.blockchain.com/btc/tx/#{hash.gsub(/:[0-9]+$/, '')})",
        "via [#{address}](https://www.blockchain.com/btc/address/#{address}),",
        "to the wallet [#{bnf.item.id}](http://www.zold.io/ledger.html?wallet=#{bnf.item.id})",
        "with the balance of #{bnf.wallet(&:balance)};",
        "BTC price at the moment of exchange was [$#{price}](https://blockchain.info/ticker);",
        "the payer is #{title_md(boss)} with the wallet",
        "[#{boss.item.id}](http://www.zold.io/ledger.html?wallet=#{boss.item.id}),",
        "the remaining balance is #{boss.wallet(&:balance)} (#{boss.wallet(&:txns).count}t)"
      )
    elsif assets.cold?(address)
      settings.telepost.spam(
        "#{format('%.06f', bitcoin)} BTC arrived to",
        "[#{address}](https://www.blockchain.com/btc/address/#{address})",
        "which doesn't belong to anyone,",
        "tx hash is [#{hash}](https://www.blockchain.com/btc/tx/#{hash.gsub(/:[0-9]+$/, '')});",
        'deposited to our fund; many thanks to whoever it was!'
      )
    else
      settings.telepost.spam(
        "#{format('%.06f', bitcoin)} BTC returned back to",
        "[#{address}](https://www.blockchain.com/btc/address/#{address})",
        'as a change from the previous payment,',
        "tx hash is [#{hash}](https://www.blockchain.com/btc/tx/#{hash.gsub(/:[0-9]+$/, '')})"
      )
    end
    assets.see(address, hash)
  end
  settings.toggles.set('latestblock', seen)
end

get '/funded' do
  raise WTS::UserError, 'E104: Amount parameter is mandatory' unless params[:amount]
  usd = params[:amount].to_f
  raise WTS::UserError, 'E105: The amount can\'t be zero' if usd.zero?
  zerocrat = user(settings.config['zerocrat']['login'])
  raise WTS::UserError, 'E191: Only Zerocrat is allowed to do this' unless user.login == zerocrat.login
  boss = user(settings.config['exchange']['login'])
  btc = usd / price
  zld = Zold::Amount.new(zld: btc / rate)
  job(boss, exclusive: true) do |jid, log|
    log.info("Buying bitcoins for $#{usd} at Coinbase...")
    ops(boss, log: log).pull
    ops(zerocrat, log: log).pull
    coinbase(log: log).buy(usd)
    txn = ops(boss, log: log).pay(
      settings.config['exchange']['keygap'],
      zerocrat.item.id,
      zld,
      "Purchased #{btc} BTC for #{usd} USD at Coinbase"
    )
    settings.telepost.spam(
      "Buy: **#{btc.round(4)}** BTC purchased for $#{usd.round(2)} at Coinbase,",
      "#{zld} were deposited to the wallet",
      "[#{zerocrat.item.id}](http://www.zold.io/ledger.html?wallet=#{zerocrat.item.id})",
      "owned by [#{zerocrat.login}](https://github.com/#{zerocrat.login})",
      "with the remaining balance of #{zerocrat.wallet(&:balance)};",
      "BTC price at the time of exchange was [$#{price.round}](https://blockchain.info/ticker);",
      "zolds were sent by [#{zerocrat.login}](https://github.com/#{zerocrat.login})",
      "from the wallet [#{boss.item.id}](http://www.zold.io/ledger.html?wallet=#{boss.item.id})",
      "with the remaining balance of #{boss.wallet(&:balance)} (#{boss.wallet(&:txns).count}t);",
      "transaction ID is #{txn.id};",
      job_link(jid)
    )
  end
  'OK, thanks'
end

post '/add-asset' do
  raise WTS::UserError, 'E129: You are not allowed to see this' unless vip?
  address = params[:address]
  assets.add_cold(address)
  flash('/assets', "Cold asset added at #{address}")
end

get '/btc-to-zld' do
  features('btc', 'buy-btc')
  address = assets.acquire(confirmed_user.login) do |a, encrypted|
    settings.telepost.spam(
      "A new bitcoin address [#{a}](https://www.blockchain.com/btc/address/#{a}) generated",
      "with this private key (it is encrypted):\n\n```\n#{encrypted.gsub(/(?<=\G.{24})/, "\n")}\n```"
    )
  end
  headers['X-Zold-BtcAddress'] = address
  haml :btc_to_zld, layout: :layout, locals: merged(
    page_title: title('buy'),
    address: address
  )
end

get '/zld-to-btc' do
  features('btc', 'sell-btc')
  haml :zld_to_btc, layout: :layout, locals: merged(
    page_title: title('sell'),
    user: confirmed_user,
    rate: rate,
    fee: fee,
    price: price
  )
end

post '/do-zld-to-btc' do
  features('sell', 'sell-btc')
  raise WTS::UserError, 'E141: Amount is not provided' if params[:amount].nil?
  raise WTS::UserError, 'E142: Bitcoin address is not provided' if params[:btc].nil?
  raise WTS::UserError, 'E143: Keygap is not provided' if params[:keygap].nil?
  amount = Zold::Amount.new(zld: params[:amount].to_f)
  min = Zold::Amount.new(zld: settings.toggles.get('min-out-btc', '0').to_f)
  raise WTS::UserError, "E195: The amount #{amount} is too small, smaller than #{min}" if amount < min
  address = params[:btc].strip
  raise WTS::UserError, "E144: Bitcoin address is not valid: #{address.inspect}" unless address =~ /^[a-zA-Z0-9]+$/
  raise WTS::UserError, 'E145: Bitcoin address must start with 1, 3 or bc1' unless address =~ /^(1|3|bc1)/
  raise WTS::UserError, "E146: You don't have enough to send #{amount}" if confirmed_user.wallet(&:balance) < amount
  if settings.toggles.get('ban:do-sell').split(',').include?(user.login)
    settings.telepost.spam(
      "The user #{title_md} from #{anon_ip} is trying to sell #{amount},",
      'while their account is banned via "ban:do-sell";',
      "the balance of the user is #{user.wallet(&:balance)}",
      "at the wallet [#{user.item.id}](http://www.zold.io/ledger.html?wallet=#{user.item.id})"
    )
    raise WTS::UserError, 'E147: Your account is not allowed to sell any ZLD at the moment, email us'
  end
  limits = settings.toggles.get('limits', '64/128/256')
  unless settings.payouts.allowed?(user.login, amount, limits) || vip?
    consumed = settings.payouts.consumed(user.login)
    settings.telepost.spam(
      "The user #{title_md} from #{anon_ip} with #{amount} payment just attempted to go",
      "over their account limits: \"#{consumed}\", while allowed thresholds are \"#{limits}\";",
      "the balance of the user is #{user.wallet(&:balance)}",
      "at the wallet [#{user.item.id}](http://www.zold.io/ledger.html?wallet=#{user.item.id})"
    )
    raise WTS::UserError, "E148: With #{amount} you are going over your limits, #{consumed} were sold already, \
while we allow one user to sell up to #{limits} (daily/weekly/monthly)"
  end
  limits = settings.toggles.get('system-limits', '512/2048/8196')
  unless settings.payouts.safe?(amount, limits) || vip?
    consumed = settings.payouts.system_consumed
    settings.telepost.spam(
      "The user #{title_md} from #{anon_ip} with #{amount} payment just attempted to go",
      "over our limits: \"#{consumed}\", while allowed thresholds are \"#{limits}\";",
      "the balance of the user is #{user.wallet(&:balance)}",
      "at the wallet [#{user.item.id}](http://www.zold.io/ledger.html?wallet=#{user.item.id})"
    )
    raise WTS::UserError, "E149: With #{amount} you are going over our limits, #{consumed} were sold by ALL \
users of WTS, while our limits are #{limits} (daily/weekly/monthly), sorry about this :("
  end
  bitcoin = (amount.to_zld(8).to_f * rate).round(8)
  if bitcoin > assets.balance(hot_only: true)
    raise WTS::UserError, "E198: The amount #{amount} is too big for us, we have only ${assets.balance}"
  end
  boss = user(settings.config['exchange']['login'])
  rewards = user(settings.config['rewards']['login'])
  job(exclusive: true) do |jid, log|
    log.info("Sending #{bitcoin} bitcoins to #{address}...")
    f = fee
    ops(log: log).pull
    ops(rewards, log: log).pull
    ops(boss, log: log).pull
    ops(log: log).pay(
      keygap,
      boss.item.id,
      amount * (1.0 - f),
      "ZLD exchange to #{bitcoin} BTC at #{address}, rate is #{rate}, fee is #{f}"
    )
    ops(log: log).pay(
      keygap,
      rewards.item.id,
      amount * f,
      "Fee for exchange of #{bitcoin} BTC at #{address}, rate is #{rate}, fee is #{f}"
    )
    ops(log: log).push
    tx = assets(log: log).pay(address, (bitcoin * 100_000_000 * (1 - fee)).round)
    log.info("Bitcoin transaction hash is #{tx}")
    settings.payouts.add(
      user.login, user.item.id, amount,
      "#{bitcoin} BTC sent to #{address}, the price was $#{price.round}/BTC, the fee was #{(f * 100).round(2)}%"
    )
    settings.telepost.spam(
      "Out: #{amount} [exchanged](https://blog.zold.io/2018/12/09/btc-to-zld.html) to #{bitcoin} BTC",
      "by #{title_md} from #{anon_ip}",
      "from the wallet [#{user.item.id}](http://www.zold.io/ledger.html?wallet=#{user.item.id})",
      "with the remaining balance of #{user.wallet(&:balance)}",
      "to bitcoin address [#{address}](https://www.blockchain.com/btc/address/#{address});",
      "BTC price at the time of exchange was [$#{price.round}](https://blockchain.info/ticker);",
      "our bitcoin assets still have [#{assets.balance.round(4)} BTC](https://wts.zold.io/assets)",
      "(worth about $#{(assets.balance * price).round});",
      "zolds were deposited to [#{boss.item.id}](http://www.zold.io/ledger.html?wallet=#{boss.item.id})",
      "of [#{boss.login}](https://github.com/#{boss.login}),",
      "the balance is #{boss.wallet(&:balance)} (#{boss.wallet(&:txns).count}t);",
      "the exchange fee of #{amount * f}",
      "was deposited to [#{rewards.item.id}](http://www.zold.io/ledger.html?wallet=#{rewards.item.id})",
      "of [#{rewards.login}](https://github.com/#{rewards.login}),",
      "the balance is #{rewards.wallet(&:balance)} (#{rewards.wallet(&:txns).count}t);",
      job_link(jid)
    )
    if boss.wallet(&:txns).count > 1000
      ops(boss, log: log).migrate(settings.config['exchange']['keygap'])
      settings.telepost.spam(
        'The office wallet has been migrated to a new place',
        "[#{boss.item.id}](http://www.zold.io/ledger.html?wallet=#{boss.item.id}),",
        "the balance is #{boss.wallet(&:balance)};",
        job_link(jid)
      )
    end
  end
  flash('/zld-to-btc', "We took #{amount} from your wallet and will send you #{bitcoin} BTC soon")
end

get '/assets' do
  features('see-assets')
  haml :assets, layout: :layout, locals: merged(
    page_title: 'Assets',
    assets: assets,
    balance: assets.balance,
    price: price,
    limit: assets.balance(hot_only: true)
  )
end

get '/assets-private-keys' do
  raise WTS::UserError, 'E129: You are not allowed to see this' unless vip?
  content_type 'text/plain'
  assets.disclose.map { |a| "#{a[:address]}: #{a[:pvt]} / #{a[:value]}" }.join("\n")
end

get '/referrals' do
  features('see-referrals')
  haml :referrals, layout: :layout, locals: merged(
    page_title: title('referrals'),
    referrals: referrals,
    fee: settings.toggles.get('referral-fee', '0.04').to_f
  )
end

def price
  settings.zache.get(:price, lifetime: 5 * 60) { assets.price }
end
