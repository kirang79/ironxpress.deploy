using Microsoft.EntityFrameworkCore;
namespace IronXpress.Models;

public class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<User> Users { get; set; }
}    
