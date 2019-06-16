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

require 'json'
require 'octokit'
require 'zold/amount'
require 'zold/id'
require 'zold/commands/pull'
require 'zold/commands/remote'
require_relative '../objects/graph'
require_relative '../objects/ticks'

set :ticks, WTS::Ticks.new(settings.pgsql, log: settings.log)

settings.daemons.start('ticks', 10 * 60) do
  settings.ticks.add('Volume24' => settings.gl.volume.to_f) unless settings.ticks.exists?('Volume24')
  settings.ticks.add('Txns24' => settings.gl.count.to_f) unless settings.ticks.exists?('Txns24')
  boss = user(settings.config['rewards']['login'])
  job(boss) do
    unless settings.ticks.exists?('Nodes')
      Zold::Remote.new(remotes: settings.remotes, log: settings.log).run(
        ['remote', "--network=#{network}", 'update', '--depth=4']
      )
      settings.ticks.add('Nodes' => settings.remotes.all.count)
    end
  end
end

settings.daemons.start('snapshot', 24 * 60 * 60) do
  next unless settings.ticks.exists?('Coverage')
  coverage = settings.ticks.latest('Coverage') / 100_000_000
  deficit = settings.ticks.latest('Deficit') / 100_000_000
  distributed = Zold::Amount.new(
    zents: (settings.ticks.latest('Emission') - settings.ticks.latest('Office')).to_i
  )
  active = settings.pgsql.exec(
    'SELECT COUNT(*) FROM item WHERE touched > NOW() - INTERVAL \'30 DAYS\''
  )[0]['count'].to_i
  release = octokit.latest_release('zold/zold')['name']
  settings.telepost.spam(
    [
      "Today is #{Time.now.utc.strftime('%d-%b-%Y')} and we are doing great:\n",
      "  Wallets: [#{settings.payables.total}](https://wts.zold.io/payables)",
      "  Active wallets: #{active} (last 30 days)",
      "  Transactions: [#{settings.payables.txns}](https://wts.zold.io/payables)",
      "  Total emission: [#{settings.payables.balance}](https://wts.zold.io/payables)",
      "  Distributed: [#{distributed}](https://wts.zold.io/rate)",
      "  24-hours volume: [#{settings.gl.volume}](https://wts.zold.io/gl)",
      "  24-hours txns count: [#{settings.gl.count}](https://wts.zold.io/gl)",
      "  Bitcoin price: [#{dollars(price)}](https://coinmarketcap.com/currencies/bitcoin/)",
      "  Bitcoin tx fee: #{dollars(sibit.fees[:XL] * 250.0 * price / 100_000_000)}",
      "  ZLD price: [#{format('%.08f', rate)}](https://wts.zold.io/rate) (#{dollars(price * rate)})",
      "  Coverage: [#{(100 * coverage / rate).round}%](http://papers.zold.io/fin-model.pdf) \
/ [#{format('%.08f', coverage)}](https://wts.zold.io/rate)",
      "  The fund: [#{assets.balance.round(4)} BTC](https://wts.zold.io/rate) \
(#{dollars(price * assets.balance)})",
      "  Deficit: [#{deficit.round(2)} BTC](https://wts.zold.io/rate)",
      '',
      "  Zold version: [#{release}](https://github.com/zold-io/zold/releases/tag/#{release})",
      "  Nodes: [#{settings.ticks.latest('Nodes').round}](https://wts.zold.io/remotes)",
      "  [HoC](https://www.yegor256.com/2014/11/14/hits-of-code.html) \
in #{repositories.count} repos: #{(hoc / 1000).round}K",
      "  GitHub stars: #{stars}",
      "\nThanks for keeping an eye on us!"
    ].join("\n")
  )
end

get '/usd_rate' do
  content_type 'text/plain'
  format('%.04f', price * rate)
end

get '/rate' do
  unless settings.zache.exists?(:rate) && !settings.zache.expired?(:rate)
    boss = user(settings.config['exchange']['login'])
    job(boss) do |_jid, log|
      ops(boss, log: log).pull
      require 'zold/commands/pull'
      Zold::Pull.new(
        wallets: settings.wallets, remotes: settings.remotes, copies: settings.copies, log: settings.log
      ).run(['pull', Zold::Id::ROOT.to_s, "--network=#{network}"])
      hash = {
        bank: assets.balance,
        boss: settings.wallets.acq(boss.item.id, &:balance),
        root: settings.wallets.acq(Zold::Id::ROOT, &:balance) * -1,
        boss_wallet: boss.item.id
      }
      hash[:rate] = hash[:bank] / (hash[:root] - hash[:boss]).to_f
      hash[:deficit] = (hash[:root] - hash[:boss]).to_f * rate - hash[:bank]
      hash[:price] = price
      hash[:usd_rate] = hash[:price] * rate
      settings.zache.put(:rate, hash, lifetime: 10 * 60)
      settings.zache.remove_by { |k| k.to_s.start_with?('http', '/') }
      unless settings.ticks.exists?('Fund')
        settings.ticks.add(
          'Fund' => (hash[:bank] * 100_000_000).to_i, # in satoshi
          'Emission' => hash[:root].to_i, # in zents
          'Office' => hash[:boss].to_i, # in zents
          'Rate' => (rate * 100_000_000).to_i, # satoshi per ZLD
          'Coverage' => (hash[:rate] * 100_000_000).to_i, # satoshi per ZLD
          'Deficit' => (hash[:deficit] * 100_000_000).to_i, # in satoshi
          'Price' => (hash[:price] * 100).to_i, # US cents per BTC
          'Value' => (hash[:usd_rate] * 100).to_i, # US cents per ZLD
          'Pledge' => (hash[:price] * hash[:rate] * 100).to_i # US cents per ZLD, covered
        )
      end
    end
  end
  flash('/', 'Still working on it, come back in a few seconds') unless settings.zache.exists?(:rate)
  haml :rate, layout: :layout, locals: merged(
    page_title: '/rate',
    formula: settings.zache.get(:rate),
    mtime: settings.zache.mtime(:rate)
  )
end

get '/rate.json' do
  content_type 'application/json'
  if settings.zache.exists?(:rate)
    hash = settings.zache.get(:rate)
    JSON.pretty_generate(
      valid: true,
      bank: hash[:bank],
      boss: hash[:boss].to_i,
      root: hash[:root].to_i,
      rate: hash[:rate].round(8),
      effective_rate: rate,
      deficit: hash[:deficit].round(2),
      price: hash[:price].round,
      usd_rate: hash[:usd_rate].round(4)
    )
  else
    JSON.pretty_generate(
      valid: false,
      effective_rate: rate,
      usd_rate: 1.0 # just for testing
    )
  end
end

get '/graph.svg' do
  raise WTS::UserError, "E156: Param 'keys' is mandatory" unless params[:keys]
  raise WTS::UserError, "E157: Param 'div' is mandatory" unless params[:div]
  raise WTS::UserError, "E158: Param 'digits' is mandatory" unless params[:digits]
  content_type 'image/svg+xml'
  settings.zache.clean
  settings.zache.get(request.url, lifetime: 10 * 60) do
    WTS::Graph.new(settings.ticks).svg(
      params[:keys].split(' '),
      params[:div].to_i,
      params[:digits].to_i,
      title: params[:title] || ''
    )
  end
end

def octokit
  Octokit::Client.new(
    login: settings.config['github']['client_id'],
    password: settings.config['github']['client_secret']
  )
end

# Names of all our repos.
def repositories
  octokit.repositories('zold').map { |json| json['full_name'] }
end

# Total amount of hits-of-code in all Zold repositories
def hoc
  repositories.map do |_r|
    0
  end.inject(&:+)
end

# Total amount of GitHub stars.
def stars
  repositories.map do |r|
    octokit.repository(r)['stargazers_count']
  end.inject(&:+)
end
